// BOSS Erkek Kuaförü — "Saçını Dene": AI protez saç simülasyonu.
//
// Gizli anahtarlar bu dosyada TUTULMAZ. Supabase Dashboard → Project Settings
// → Edge Functions → Secrets:
//   FAL_KEY                      (zorunlu, fal.ai API anahtarı)
//   FAL_MODEL                    (opsiyonel, varsayılan: fal-ai/nano-banana/edit;
//                                 "fal-ai/flux-pro/kontext" de desteklenir)
//   HAIR_TRYON_DAILY_LIMIT       (opsiyonel, IP başına günlük üretim, varsayılan 6)
//   HAIR_TRYON_ALLOWED_ORIGINS   (opsiyonel, virgülle ayrılmış ek origin listesi)
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY platform tarafından otomatik verilir.
//
// Aksiyonlar (POST JSON):
//   { action: "generate", tryon_id, look_id, density? }  → AI görseli üretir
//   { action: "finalize", tryon_id, appointment_id }     → randevuya bağlar + Telegram

import { createClient } from "npm:@supabase/supabase-js@2";

const PHOTO_BUCKET = "tryon-photos";
const RESULT_BUCKET = "tryon-results";
const FAL_MODEL = Deno.env.get("FAL_MODEL") ?? "fal-ai/nano-banana/edit";
const DAILY_LIMIT = Number(Deno.env.get("HAIR_TRYON_DAILY_LIMIT") ?? "6");
const MAX_RESULTS_PER_TRYON = 12;

// ============ CORS ============
const SITE_ORIGINS = ["https://bosskuafor.com", "https://www.bosskuafor.com"];
const DEFAULT_ORIGIN_PATTERNS = [
  /^http:\/\/localhost:\d+$/,
  /^http:\/\/127\.0\.0\.1:\d+$/,
  /^https:\/\/[a-z0-9-]+\.github\.io$/i,
  /^https:\/\/[a-z0-9-]+\.vercel\.app$/i,
  /^https:\/\/[a-z0-9-]+\.netlify\.app$/i,
];
const EXTRA_ORIGINS = (Deno.env.get("HAIR_TRYON_ALLOWED_ORIGINS") ?? "")
  .split(",").map((o) => o.trim()).filter(Boolean);

function corsHeaders(origin: string | null): Record<string, string> {
  const allowed = origin !== null &&
    (SITE_ORIGINS.includes(origin) || EXTRA_ORIGINS.includes(origin) ||
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

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
type Db = ReturnType<typeof createClient>;

// ============ Yardımcılar ============
async function sha256Hex(text: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function clientIpHash(req: Request): Promise<string> {
  const ip = req.headers.get("cf-connecting-ip") ??
    req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ?? "unknown";
  const salt = (Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "").slice(-16);
  return (await sha256Hex(`${ip}|${salt}`)).slice(0, 32);
}

function bytesToBase64(buf: Uint8Array): string {
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < buf.length; i += chunk) {
    binary += String.fromCharCode(...buf.subarray(i, i + chunk));
  }
  return btoa(binary);
}

const DENSITY_TEXT: Record<string, string> = {
  light: "light, natural-looking density with slightly visible scalp at the temples and hairline, subtle and understated",
  natural: "natural, healthy medium density, evenly covering the scalp the way real hair grows",
  full: "thick, full, dense coverage with no visible scalp thinning",
};

const COLOR_TEXT: Record<string, string> = {
  natural: "hair color that naturally matches the person's eyebrows, beard and skin tone, with subtle natural color variation",
  black: "natural jet black hair with soft dark-brown depth in the light",
  dark_brown: "dark brown hair (espresso brown), natural tonal variation",
  chestnut: "chestnut medium brown hair (kumral), warm natural tones with subtle lighter strands",
  light_brown: "light brown hair (light chestnut) with natural lighter highlights",
  blonde: "dark blonde / sandy blonde hair, natural not bleached",
  gray: "natural salt-and-pepper gray hair, a realistic mix of gray and dark strands",
};
const COLOR_LABEL: Record<string, string> = {
  natural: "Doğal", black: "Siyah", dark_brown: "Koyu Kahve", chestnut: "Kumral",
  light_brown: "Açık Kumral", blonde: "Sarı", gray: "Gri (Kırlaşmış)",
};

function buildPrompt(lookPrompt: string, density: string, color: string): string {
  return (
    `Edit this photo of a man who is bald or has very thin hair on top. Show how he would look with a high-quality, undetectable natural hair system (hair replacement) fitted to his own head, in this style: ${lookPrompt}. ` +
    `Hair density: ${DENSITY_TEXT[density] ?? DENSITY_TEXT.natural}. ` +
    `Hair color: ${COLOR_TEXT[color] ?? COLOR_TEXT.natural}. ` +
    "STRICT RULES: keep the person's face, identity, facial features, skin texture, facial hair, eyebrows, ears, " +
    "expression, head pose, clothing, background, framing and camera angle EXACTLY unchanged — only the scalp/hair region may change. " +
    "Create a soft, slightly irregular, natural hairline with fine baby hairs at the forehead and temples (no hard straight line, no wig or toupee look). " +
    "Hair must follow the true shape and volume of his skull, with realistic individual strands, natural shine and shadows consistent with the lighting of the original photo. " +
    "Photorealistic, high detail, no blur, no painting or CGI look, no text, no watermark."
  );
}

async function callFal(imageDataUri: string, prompt: string): Promise<string> {
  const falKey = Deno.env.get("FAL_KEY");
  if (!falKey) throw new Error("FAL_KEY_MISSING");

  const isKontext = FAL_MODEL.includes("kontext");
  const input = isKontext
    ? { prompt, image_url: imageDataUri, num_images: 1, output_format: "jpeg", safety_tolerance: "2" }
    : { prompt, image_urls: [imageDataUri], num_images: 1, output_format: "jpeg" };

  const res = await fetch(`https://fal.run/${FAL_MODEL}`, {
    method: "POST",
    headers: { "Authorization": `Key ${falKey}`, "Content-Type": "application/json" },
    body: JSON.stringify(input),
  });
  if (!res.ok) {
    throw new Error(`fal ${res.status}: ${(await res.text()).slice(0, 300)}`);
  }
  const out = await res.json();
  const url = out?.images?.[0]?.url ?? out?.image?.url;
  if (typeof url !== "string") throw new Error("fal: görsel dönmedi");
  return url;
}

async function signed(db: Db, bucket: string, path: string, seconds: number): Promise<string | null> {
  const { data, error } = await db.storage.from(bucket).createSignedUrl(path, seconds);
  return error ? null : data.signedUrl;
}

// ============ generate ============
async function handleGenerate(req: Request, body: Record<string, unknown>, db: Db, origin: string | null) {
  const tryonId = body.tryon_id;
  const lookId = body.look_id;
  const density = typeof body.density === "string" && body.density in DENSITY_TEXT ? body.density : "natural";
  const color = typeof body.hair_color === "string" && body.hair_color in COLOR_TEXT ? body.hair_color : "natural";
  if (typeof tryonId !== "string" || !UUID_RE.test(tryonId)) return json({ error: "invalid_tryon_id" }, 400, origin);
  if (typeof lookId !== "string" || !UUID_RE.test(lookId)) return json({ error: "invalid_look_id" }, 400, origin);

  const { data: tryon } = await db.from("hair_tryons")
    .select("id, photo_path, appointment_id").eq("id", tryonId).maybeSingle();
  if (!tryon || !tryon.photo_path) {
    return json({ status: "failed", message: "Fotoğraf bulunamadı, lütfen tekrar yükleyin." }, 200, origin);
  }

  const { data: look } = await db.from("hair_looks")
    .select("id, name, prompt").eq("id", lookId).eq("active", true).maybeSingle();
  if (!look) return json({ status: "failed", message: "Model bulunamadı." }, 200, origin);

  if (!Deno.env.get("FAL_KEY")) {
    console.error("FAL_KEY secret ayarlanmamış.");
    return json({ status: "failed", message: "Şu an görsel üretilemiyor, lütfen daha sonra tekrar deneyin." }, 200, origin);
  }

  // Maliyet kontrolü: IP başına günlük limit + deneme başına üst sınır.
  const ipHash = await clientIpHash(req);
  const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
  const [{ count: ipCount }, { count: tryonCount }] = await Promise.all([
    db.from("hair_tryon_results").select("id", { count: "exact", head: true })
      .eq("ip_hash", ipHash).gte("created_at", since).neq("status", "failed"),
    db.from("hair_tryon_results").select("id", { count: "exact", head: true })
      .eq("tryon_id", tryonId).neq("status", "failed"),
  ]);
  if ((ipCount ?? 0) >= DAILY_LIMIT || (tryonCount ?? 0) >= MAX_RESULTS_PER_TRYON) {
    return json({
      status: "limited",
      message: "Bugünlük deneme hakkınız doldu. Dilerseniz randevu alıp ustamızla birlikte devam edebilirsiniz.",
    }, 200, origin);
  }

  const { data: resultRow, error: insErr } = await db.from("hair_tryon_results").insert({
    tryon_id: tryonId, look_id: look.id, look_name: look.name, density, hair_color: color, status: "processing", ip_hash: ipHash,
  }).select("id").single();
  if (insErr || !resultRow) {
    console.error("sonuç satırı oluşturulamadı", insErr);
    return json({ status: "failed", message: "Bir sorun oluştu, lütfen tekrar deneyin." }, 200, origin);
  }

  const fail = async (msg: string, userMsg: string) => {
    await db.from("hair_tryon_results").update({ status: "failed", error_message: msg.slice(0, 500) }).eq("id", resultRow.id);
    return json({ status: "failed", message: userMsg }, 200, origin);
  };

  try {
    const { data: photo, error: dlErr } = await db.storage.from(PHOTO_BUCKET).download(tryon.photo_path as string);
    if (dlErr || !photo) return await fail("foto indirilemedi", "Fotoğraf okunamadı, lütfen tekrar yükleyin.");
    const mime = photo.type && photo.type.startsWith("image/") ? photo.type : "image/jpeg";
    const dataUri = `data:${mime};base64,${bytesToBase64(new Uint8Array(await photo.arrayBuffer()))}`;

    const falUrl = await callFal(dataUri, buildPrompt(look.prompt as string, density, color));

    const imgRes = await fetch(falUrl);
    if (!imgRes.ok) throw new Error(`sonuç indirilemedi: ${imgRes.status}`);
    const imgBytes = new Uint8Array(await imgRes.arrayBuffer());
    const contentType = imgRes.headers.get("content-type")?.startsWith("image/")
      ? imgRes.headers.get("content-type")! : "image/jpeg";
    const ext = contentType.includes("png") ? "png" : contentType.includes("webp") ? "webp" : "jpg";
    const resultPath = `${tryonId}/${resultRow.id}.${ext}`;

    const { error: upErr } = await db.storage.from(RESULT_BUCKET).upload(resultPath, imgBytes, { contentType });
    if (upErr) throw new Error(`sonuç yüklenemedi: ${upErr.message}`);

    await db.from("hair_tryon_results").update({ status: "completed", image_path: resultPath }).eq("id", resultRow.id);

    const imageUrl = await signed(db, RESULT_BUCKET, resultPath, 3600);
    return json({
      status: "completed", result_id: resultRow.id, look_id: look.id, look_name: look.name, density, hair_color: color, image_url: imageUrl,
    }, 200, origin);
  } catch (err) {
    console.error("hair-tryon generate hatası", err);
    return await fail(String(err instanceof Error ? err.message : err),
      "Görsel oluşturulurken bir sorun oluştu, lütfen tekrar deneyin.");
  }
}

// ============ finalize ============
const DENSITY_LABEL: Record<string, string> = { light: "Hafif", natural: "Doğal", full: "Dolgun" };

async function handleFinalize(body: Record<string, unknown>, db: Db, origin: string | null) {
  const tryonId = body.tryon_id;
  const appointmentId = body.appointment_id;
  if (typeof tryonId !== "string" || !UUID_RE.test(tryonId) ||
      typeof appointmentId !== "string" || !UUID_RE.test(appointmentId)) {
    return json({ error: "invalid_ids" }, 400, origin);
  }

  const { data, error } = await db.rpc("link_hair_tryon_to_appointment", {
    p_tryon_id: tryonId, p_appointment_id: appointmentId,
  });
  const row = Array.isArray(data) ? data[0] : data;
  if (error || !row) {
    console.error("link_hair_tryon_to_appointment", error);
    return json({ status: "failed" }, 200, origin);
  }

  // Telegram başarısız olsa bile bağlantı kurulmuş olur.
  try {
    const week = 7 * 24 * 3600;
    const [originalUrl, resultUrl] = await Promise.all([
      signed(db, PHOTO_BUCKET, row.original_path, week),
      signed(db, RESULT_BUCKET, row.result_path, week),
    ]);
    if (originalUrl && resultUrl) {
      const caption = `Müşteri: ${row.customer_name}\nİstediği model: ${row.look_name} (${DENSITY_LABEL[row.density] ?? row.density} yoğunluk, ${COLOR_LABEL[row.hair_color] ?? row.hair_color} renk)`;
      const { error: nErr } = await db.rpc("notify_telegram_hair_tryon", {
        p_tryon_id: tryonId, p_original_url: originalUrl, p_result_url: resultUrl, p_caption: caption,
      });
      if (nErr) console.error("telegram bildirimi", nErr);
    }
  } catch (err) {
    console.error("finalize bildirim hatası", err);
  }
  return json({ status: "linked" }, 200, origin);
}

// ============ HTTP ============
Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders(origin) });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405, origin);

  const body = await req.json().catch(() => null);
  if (!body || typeof body !== "object") return json({ error: "invalid_body" }, 400, origin);

  const db = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");

  if (body.action === "generate") return await handleGenerate(req, body, db, origin);
  if (body.action === "finalize") return await handleFinalize(body, db, origin);
  return json({ error: "unknown_action" }, 400, origin);
});
