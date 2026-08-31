// BOSS Erkek Kuaförü — "Bana Ne Yakışır?" stil analizi (Claude vision).
//
// Gizli anahtarlar bu dosyada TUTULMAZ. Supabase Dashboard → Project
// Settings → Edge Functions → Secrets:
//   ANTHROPIC_API_KEY            (zorunlu, chat fonksiyonuyla ortak)
//   STYLE_ANALYSIS_ALLOWED_ORIGINS (opsiyonel, virgülle ayrılmış ek origin listesi)
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY platform tarafından otomatik verilir.
//
// KRITIK: bu fonksiyonun HTTP yaniti SADECE {status} veya {status, message}
// icerebilir. recommendations (rank 1/2 dahil) hicbir zaman client'a
// donmemeli — musteri sadece get_style_analysis_reveal RPC'siyle rank=3'u
// gorur, rank 1/2 sadece randevu onaylaninca Telegram'a gider.

import Anthropic from "npm:@anthropic-ai/sdk";
import { createClient } from "npm:@supabase/supabase-js@2";

const MODEL = "claude-sonnet-5";
const BUCKET = "style-photos";

// ============ CORS ============
const SITE_ORIGINS = [
  "https://bosskuafor.com",
  "https://www.bosskuafor.com",
];

const DEFAULT_ORIGIN_PATTERNS = [
  /^http:\/\/localhost:\d+$/,
  /^http:\/\/127\.0\.0\.1:\d+$/,
  /^https:\/\/[a-z0-9-]+\.github\.io$/i,
  /^https:\/\/[a-z0-9-]+\.vercel\.app$/i,
  /^https:\/\/[a-z0-9-]+\.netlify\.app$/i,
];

const EXTRA_ORIGINS = (Deno.env.get("STYLE_ANALYSIS_ALLOWED_ORIGINS") ?? "")
  .split(",")
  .map((o) => o.trim())
  .filter(Boolean);

function corsHeaders(origin: string | null): Record<string, string> {
  const allowed = origin !== null &&
    (SITE_ORIGINS.includes(origin) ||
      EXTRA_ORIGINS.includes(origin) ||
      DEFAULT_ORIGIN_PATTERNS.some((re) => re.test(origin)));
  if (!allowed) return {};
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Headers": "authorization, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

function json(body: unknown, status: number, origin: string | null): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders(origin) },
  });
}

// ============ Yardımcılar ============
type CatalogRow = {
  id: string;
  name: string;
  description: string | null;
  image_url: string;
  tags: string[];
};

type Db = ReturnType<typeof createClient>;

const SUBMIT_TOOL: Anthropic.Tool = {
  name: "submit_recommendations",
  description: "Müşteriye en uygun 3 stili, en iyiden en aza sıralayarak bildir.",
  input_schema: {
    type: "object",
    properties: {
      picks: {
        type: "array",
        minItems: 3,
        maxItems: 3,
        items: {
          type: "object",
          properties: {
            style_id: {
              type: "string",
              description: "Seçilen stilin katalog id'si (uuid), verilen listeden birebir kopyalanmalı.",
            },
            reason: {
              type: "string",
              description: "Bu stilin bu yüze neden uyduğu, 1-2 cümle, Türkçe, müşteriye hitaben sıcak bir tonda.",
            },
          },
          required: ["style_id", "reason"],
        },
      },
    },
    required: ["picks"],
  },
};

async function downloadAsBase64(
  db: Db,
  path: string,
): Promise<{ data: string; mediaType: string }> {
  const { data, error } = await db.storage.from(BUCKET).download(path);
  if (error || !data) throw new Error(`fotoğraf indirilemedi: ${path}`);
  const buf = new Uint8Array(await data.arrayBuffer());
  let binary = "";
  for (let i = 0; i < buf.length; i++) binary += String.fromCharCode(buf[i]);
  const base64 = btoa(binary);
  const mediaType = data.type && data.type.startsWith("image/") ? data.type : "image/jpeg";
  return { data: base64, mediaType };
}

async function markFailed(db: Db, analysisId: string, message: string) {
  await db.from("style_analyses").update({
    status: "failed",
    error_message: message,
    updated_at: new Date().toISOString(),
  }).eq("id", analysisId);
}

// ============ HTTP ============
Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");

  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders(origin) });
  }
  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405, origin);
  }

  const body = await req.json().catch(() => null);
  const analysisId = body?.analysis_id;
  if (typeof analysisId !== "string" || !/^[0-9a-f-]{36}$/i.test(analysisId)) {
    return json({ error: "invalid_analysis_id" }, 400, origin);
  }

  const db = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  );

  // İyimser kilitleme: sadece 'pending' iken 'processing'e geçebiliriz.
  // Bu, aynı analiz için iki kez tetiklenen çağrının işi tekrar etmesini engeller.
  const { data: claimed, error: claimError } = await db
    .from("style_analyses")
    .update({ status: "processing", updated_at: new Date().toISOString() })
    .eq("id", analysisId)
    .eq("status", "pending")
    .select("id, photo_front_path, photo_side_path, photo_back_path")
    .maybeSingle();

  if (claimError) {
    console.error("claim hatası", claimError);
    return json({ status: "failed", message: "Analiz başlatılamadı." }, 200, origin);
  }

  if (!claimed) {
    const { data: existing } = await db
      .from("style_analyses").select("status").eq("id", analysisId).maybeSingle();
    return json({ status: existing?.status ?? "failed" }, 200, origin);
  }

  if (!claimed.photo_front_path || !claimed.photo_side_path || !claimed.photo_back_path) {
    await markFailed(db, analysisId, "Fotoğraflar eksik.");
    return json({ status: "failed", message: "Fotoğraflar eksik, lütfen tekrar deneyin." }, 200, origin);
  }

  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) {
    console.error("ANTHROPIC_API_KEY secret ayarlanmamış.");
    await markFailed(db, analysisId, "AI servisi yapılandırılmamış.");
    return json({ status: "failed", message: "Şu an analiz yapılamıyor, lütfen daha sonra tekrar deneyin." }, 200, origin);
  }

  try {
    const { data: catalogRows, error: catalogError } = await db
      .from("style_catalog")
      .select("id,name,description,image_url,tags")
      .eq("active", true)
      .order("sort_order");

    if (catalogError || !catalogRows || catalogRows.length < 3) {
      throw new Error("stil kataloğu yetersiz");
    }
    const catalog = catalogRows as unknown as CatalogRow[];

    const [front, side, back] = await Promise.all([
      downloadAsBase64(db, claimed.photo_front_path as string),
      downloadAsBase64(db, claimed.photo_side_path as string),
      downloadAsBase64(db, claimed.photo_back_path as string),
    ]);

    const catalogList = catalog
      .map((c) => `- id: ${c.id} | ${c.name} | ${c.description ?? ""} | etiketler: ${(c.tags ?? []).join(", ")}`)
      .join("\n");

    const client = new Anthropic({ apiKey });
    const response = await client.messages.create({
      model: MODEL,
      max_tokens: 1024,
      system:
        "Sen bir erkek kuaförü stil danışmanısın. Sana bir müşterinin 3 açıdan " +
        "fotoğrafı verilecek (ön yüz, yan profil, ense). Yüz şekli, saç yapısı ve " +
        "orantılarına bakarak, verilen katalogdan TAM OLARAK 3 farklı stili, en çok " +
        "yakışacaktan en aza doğru sıralayarak seç. Üçü de gerçekten uygun, kaliteli " +
        "seçimler olmalı — sırf çeşitlilik için kötü bir seçim ekleme. Her seçim için " +
        "müşteriye hitaben sıcak, kısa (1-2 cümle) bir Türkçe gerekçe yaz. Sonucu " +
        "SADECE submit_recommendations aracıyla bildir.",
      tools: [SUBMIT_TOOL],
      tool_choice: { type: "tool", name: "submit_recommendations" },
      messages: [{
        role: "user",
        content: [
          { type: "text", text: "ÖN YÜZ:" },
          { type: "image", source: { type: "base64", media_type: front.mediaType as Anthropic.Base64ImageSource["media_type"], data: front.data } },
          { type: "text", text: "YAN PROFİL:" },
          { type: "image", source: { type: "base64", media_type: side.mediaType as Anthropic.Base64ImageSource["media_type"], data: side.data } },
          { type: "text", text: "ENSE:" },
          { type: "image", source: { type: "base64", media_type: back.mediaType as Anthropic.Base64ImageSource["media_type"], data: back.data } },
          { type: "text", text: `Stil kataloğu:\n${catalogList}` },
        ],
      }],
    });

    const toolUse = response.content.find(
      (b): b is Anthropic.ToolUseBlock => b.type === "tool_use" && b.name === "submit_recommendations",
    );
    if (!toolUse) throw new Error("model araç çağırmadı");

    const picks = (toolUse.input as { picks?: Array<{ style_id: string; reason: string }> }).picks ?? [];
    if (picks.length !== 3) throw new Error("3 seçim gelmedi");

    const seen = new Set<string>();
    const recommendations = picks.map((pick, index) => {
      const row = catalog.find((c) => c.id === pick.style_id);
      if (!row) throw new Error(`bilinmeyen style_id: ${pick.style_id}`);
      if (seen.has(row.id)) throw new Error("tekrarlanan style_id");
      seen.add(row.id);
      return {
        rank: index + 1,
        style_id: row.id,
        style_name: row.name,
        description: row.description,
        image_url: row.image_url,
        reason: pick.reason,
      };
    });

    await db.from("style_analyses").update({
      status: "completed",
      recommendations,
      updated_at: new Date().toISOString(),
    }).eq("id", analysisId);

    return json({ status: "completed" }, 200, origin);
  } catch (err) {
    console.error("style-analysis hatası", err);
    await markFailed(db, analysisId, String(err instanceof Error ? err.message : err));
    return json({ status: "failed", message: "Analiz sırasında bir sorun oluştu, lütfen tekrar deneyin." }, 200, origin);
  }
});
