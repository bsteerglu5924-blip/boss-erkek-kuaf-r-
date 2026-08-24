// BOSS Erkek Kuaförü — randevu asistanı (Claude Haiku 4.5).
//
// Gizli anahtarlar bu dosyada TUTULMAZ. Supabase Dashboard →
// Project Settings → Edge Functions → Secrets üzerinden verilir:
//   ANTHROPIC_API_KEY     (zorunlu)
//   CHAT_IP_SALT          (zorunlu — IP hash'leme tuzu)
//   CHAT_ALLOWED_ORIGINS  (opsiyonel, virgülle ayrılmış ek origin listesi)
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY platform tarafından otomatik verilir.

import Anthropic from "npm:@anthropic-ai/sdk";
import { createClient } from "npm:@supabase/supabase-js@2";

const MODEL = "claude-haiku-4-5";
const MAX_TOOL_ITERATIONS = 5;
const MAX_MESSAGE_LENGTH = 1000;

const WHATSAPP_URL =
  "https://wa.me/905451166205?text=Merhaba%2C%20randevu%20almak%20istiyorum.";

const FALLBACK_REPLY =
  "Şu an size cevap veremiyorum. Randevu ve sorularınız için 0545 116 62 05'i arayabilir " +
  "ya da WhatsApp'tan yazabilirsiniz: " + WHATSAPP_URL;

const LIMIT_REPLIES: Record<string, string> = {
  SESSION_LIMIT:
    "Bu sohbet için mesaj sınırına ulaştık. Kaldığımız yerden devam etmek için " +
    "0545 116 62 05'i arayabilir ya da WhatsApp'tan yazabilirsiniz: " + WHATSAPP_URL,
  DAILY_LIMIT:
    "Bugünlük mesaj sınırına ulaşıldı. Lütfen 0545 116 62 05'i arayın ya da " +
    "WhatsApp'tan yazın: " + WHATSAPP_URL,
  SESSION_MISMATCH:
    "Oturumunuzun süresi doldu. Lütfen sayfayı yenileyip tekrar deneyin.",
  EMPTY_MESSAGE: "Mesajınızı yazar mısınız?",
};

// ============ CORS ============
const DEFAULT_ORIGIN_PATTERNS = [
  /^http:\/\/localhost:\d+$/,
  /^http:\/\/127\.0\.0\.1:\d+$/,
  /^https:\/\/[a-z0-9-]+\.github\.io$/i,
  /^https:\/\/[a-z0-9-]+\.vercel\.app$/i,
  /^https:\/\/[a-z0-9-]+\.netlify\.app$/i,
];

const EXTRA_ORIGINS = (Deno.env.get("CHAT_ALLOWED_ORIGINS") ?? "")
  .split(",")
  .map((o) => o.trim())
  .filter(Boolean);

function corsHeaders(origin: string | null): Record<string, string> {
  const allowed = origin !== null &&
    (EXTRA_ORIGINS.includes(origin) ||
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
async function hashIp(ip: string): Promise<string> {
  const salt = Deno.env.get("CHAT_IP_SALT") ?? "";
  const bytes = new TextEncoder().encode(ip + salt);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// "Sakal & Tıraş" ile "sakal ve tiras" eşleşsin diye.
function normalize(s: string): string {
  return s
    .toLocaleLowerCase("tr-TR")
    .replaceAll("ı", "i").replaceAll("ş", "s").replaceAll("ğ", "g")
    .replaceAll("ü", "u").replaceAll("ö", "o").replaceAll("ç", "c")
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

function findByName<T extends { name: string }>(rows: T[], query: string): T | null {
  const q = normalize(query);
  if (!q) return null;
  return rows.find((r) => normalize(r.name) === q)
    ?? rows.find((r) => normalize(r.name).includes(q) || q.includes(normalize(r.name)))
    ?? null;
}

const timeFmt = new Intl.DateTimeFormat("tr-TR", {
  timeZone: "Europe/Istanbul", hour: "2-digit", minute: "2-digit",
});
const dateTimeFmt = new Intl.DateTimeFormat("tr-TR", {
  timeZone: "Europe/Istanbul", day: "2-digit", month: "long", year: "numeric",
  weekday: "long", hour: "2-digit", minute: "2-digit",
});

function todayIstanbul(): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: "Europe/Istanbul", year: "numeric", month: "2-digit", day: "2-digit",
  }).format(new Date());
}

// index.html'deki ERROR_MESSAGES ile aynı metinler.
const BOOKING_ERRORS: Record<string, string> = {
  SLOT_UNAVAILABLE: "Bu saat az önce doldu, lütfen başka bir saat seçin.",
  SLOT_IN_PAST: "Bu saat artık geçmişte kaldı, lütfen başka bir saat seçin.",
  BARBER_UNAVAILABLE: "Seçilen berber şu an müsait değil.",
  SERVICE_UNAVAILABLE: "Seçilen hizmet şu an müsait değil.",
  MISSING_CUSTOMER_INFO: "Ad soyad ve telefon zorunludur.",
};

// ============ Sistem promptu ============
// SABİT TUTULMALI — prompt cache prefix'i buna bağlı. Tarih gibi değişken
// bilgi ikinci system bloğuna, cache breakpoint'inden SONRA gider.
const SYSTEM_PROMPT = `Sen BOSS Erkek Kuaförü'nün online randevu asistanısın. Erzincan Merkez'deki bu salon adına müşterilerle Türkçe konuşuyorsun.

## Salon bilgileri
- Adres: İnönü Mahallesi, Ordu Caddesi, Selimoğlu İş Hanı Zemin Kat, Erzincan Merkez
- Harita: https://www.google.com/maps/place/BOSS+ERKEK+KUAF%C3%96R%C3%9C/@39.7476021,39.4908903,17z
- Telefon: 0545 116 62 05
- WhatsApp: ${WHATSAPP_URL}
- Çalışma saatleri: Her gün 08:30 – 20:30
- Ekip: Ali Şengül (Matematiksel Kesim uzmanı), Murat Cankaya (saç, sakal ve tıraş ustası), Furkan Akar (protez saç uygulamaları ustası)
- Öne çıkan uzmanlıklar: matematiksel kesim, protez saç, altın oran kaş tasarımı

## Araçların
- list_services: güncel hizmet listesi, süreleri ve fiyat durumu
- list_barbers: çalışan berberler
- get_available_slots: belirli bir berber, hizmet ve tarih için boş saatler
- create_appointment: randevuyu oluşturur

## Kurallar
1. Hizmet, süre veya fiyat sorulduğunda MUTLAKA list_services çağır. Ezberden hizmet adı ya da süre söyleme.
2. Bir hizmetin fiyatı kesinleşmemişse ASLA fiyat uydurma veya tahmin etme. "Fiyat bilgisi için 0545 116 62 05'i arayabilirsiniz" de.
3. Boş saat sorulduğunda MUTLAKA get_available_slots çağır. Saat uydurma.
4. Randevu oluşturmadan önce hizmet, berber, tarih, saat, ad soyad ve telefonu özetle ve müşteriden açık onay iste ("Onaylıyor musunuz?"). Müşteri açıkça onaylamadan create_appointment ÇAĞIRMA.
5. Ad soyad ve telefon numarası olmadan randevu oluşturma.
6. Müşteri berber tercihi belirtmezse berberleri listele ve seçmesini iste; kendin seçme.
7. Mevcut bir randevuyu iptal etme veya değiştirme yetkin yok. Böyle bir talepte 0545 116 62 05'i aramasını ya da WhatsApp'tan yazmasını söyle.
8. Salonla ilgisi olmayan konularda yardımcı olamayacağını kibarca söyle ve konuyu randevuya getir.
9. Emin olmadığın hiçbir şeyi söyleme. Bilmediğinde WhatsApp'a veya telefona yönlendir.
10. "Randevunuz oluşturuldu" cümlesini SADECE create_appointment aracı bu turda başarılı sonuç döndürdüyse kur. Araç çağırmadan ya da araçtan HATA döndüyse asla randevu oluşturulduğunu söyleme; onun yerine sorunu açıkla ve telefona/WhatsApp'a yönlendir.
11. Bir aracın sonucunu hatırladığını varsayma. Saat, tarih veya fiyat söylemen gereken her turda ilgili aracı yeniden çağır.

## Üslup
- Kibar, sıcak ama kısa. Genelde 2-4 cümle.
- Siz diliyle konuş. Abartılı emoji kullanma, en fazla bir tane.
- Madde madde liste sadece hizmet veya saat listelerken kullan.`;

// ============ Tool tanımları ============
const TOOLS = [
  {
    name: "list_services",
    description:
      "Salonun aktif hizmetlerini, sürelerini ve fiyat durumunu döndürür. " +
      "Hizmet, süre veya fiyat sorulduğunda her zaman çağır.",
    input_schema: { type: "object" as const, properties: {}, required: [] },
  },
  {
    name: "list_barbers",
    description: "Salonda çalışan aktif berberleri ve uzmanlıklarını döndürür.",
    input_schema: { type: "object" as const, properties: {}, required: [] },
  },
  {
    name: "get_available_slots",
    description:
      "Belirli bir berber, hizmet ve tarih için boş randevu saatlerini döndürür. " +
      "Tarih YYYY-MM-DD biçiminde olmalı.",
    input_schema: {
      type: "object" as const,
      properties: {
        barber_name: { type: "string", description: "Berberin adı, örn. 'Ali Şengül'" },
        service_name: { type: "string", description: "Hizmetin adı, örn. 'Saç Kesimi'" },
        date: { type: "string", description: "Tarih, YYYY-MM-DD biçiminde" },
      },
      required: ["barber_name", "service_name", "date"],
    },
  },
  {
    name: "create_appointment",
    description:
      "Randevuyu oluşturur. Yalnızca müşteri özeti görüp açıkça onayladıktan sonra çağır. " +
      "starts_at, get_available_slots'un döndürdüğü starts_at değerlerinden biri olmalı.",
    input_schema: {
      type: "object" as const,
      properties: {
        barber_name: { type: "string" },
        service_name: { type: "string" },
        starts_at: {
          type: "string",
          description: "Randevu başlangıcı, get_available_slots'tan gelen ISO 8601 değeri",
        },
        customer_name: { type: "string", description: "Müşterinin ad soyadı" },
        customer_phone: { type: "string", description: "Müşterinin telefon numarası" },
        notes: { type: "string", description: "Opsiyonel not" },
      },
      required: ["barber_name", "service_name", "starts_at", "customer_name", "customer_phone"],
    },
  },
];

// ============ Tool çalıştırma ============
type Db = ReturnType<typeof createClient>;

async function resolveBarber(db: Db, query: string) {
  const { data } = await db.from("barbers").select("id,name").eq("active", true).order("sort_order");
  return findByName((data ?? []) as Array<{ id: string; name: string }>, query);
}

async function resolveService(db: Db, query: string) {
  const { data } = await db.from("services").select("id,name").eq("active", true).order("sort_order");
  return findByName((data ?? []) as Array<{ id: string; name: string }>, query);
}

async function runTool(
  db: Db,
  sessionId: string,
  name: string,
  input: Record<string, unknown>,
): Promise<string> {
  if (name === "list_services") {
    const { data, error } = await db
      .from("services")
      .select("name,description,duration_minutes,price_try,price_is_final")
      .eq("active", true)
      .order("sort_order");
    if (error) return "Hizmetler okunamadı.";
    return JSON.stringify(
      (data ?? []).map((s: Record<string, unknown>) => ({
        ad: s.name,
        aciklama: s.description,
        sure_dakika: s.duration_minutes,
        fiyat: s.price_is_final
          ? `${s.price_try} TL`
          : "Fiyat kesinleşmedi — telefonla bilgi alınmalı, tahmin etme",
      })),
    );
  }

  if (name === "list_barbers") {
    const { data, error } = await db
      .from("barbers").select("name,title").eq("active", true).order("sort_order");
    if (error) return "Berberler okunamadı.";
    return JSON.stringify(
      (data ?? []).map((b: Record<string, unknown>) => ({ ad: b.name, unvan: b.title })),
    );
  }

  if (name === "get_available_slots") {
    const date = String(input.date ?? "");
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) {
      return "HATA: date YYYY-MM-DD biçiminde olmalı.";
    }
    const barber = await resolveBarber(db, String(input.barber_name ?? ""));
    if (!barber) return "HATA: Bu isimde bir berber bulunamadı. Önce list_barbers çağır.";
    const service = await resolveService(db, String(input.service_name ?? ""));
    if (!service) return "HATA: Bu isimde bir hizmet bulunamadı. Önce list_services çağır.";

    const { data, error } = await db.rpc("get_available_slots", {
      p_barber_id: barber.id, p_service_id: service.id, p_date: date,
    });
    if (error) return "Saatler okunamadı, müşteriden tekrar denemesini iste.";
    const slots = (data ?? []) as Array<{ slot_start: string }>;
    if (!slots.length) {
      return `${barber.name} için ${date} tarihinde ${service.name} hizmetine uygun saat kalmamış. Başka bir tarih veya berber öner.`;
    }
    return JSON.stringify({
      berber: barber.name,
      hizmet: service.name,
      tarih: date,
      bos_saatler: slots.map((s) => ({
        saat: timeFmt.format(new Date(s.slot_start)),
        starts_at: s.slot_start,
      })),
    });
  }

  if (name === "create_appointment") {
    const barber = await resolveBarber(db, String(input.barber_name ?? ""));
    if (!barber) return "HATA: Bu isimde bir berber bulunamadı.";
    const service = await resolveService(db, String(input.service_name ?? ""));
    if (!service) return "HATA: Bu isimde bir hizmet bulunamadı.";

    const startsAt = String(input.starts_at ?? "");
    if (Number.isNaN(Date.parse(startsAt))) {
      return "HATA: starts_at geçerli bir tarih-saat değil. get_available_slots'tan gelen starts_at değerini aynen kullan.";
    }

    const customerName = String(input.customer_name ?? "").trim();
    const rawPhone = String(input.customer_phone ?? "").trim();
    const phoneDigits = rawPhone.replace(/\D/g, "");
    if (customerName.length < 2) return "HATA: Müşterinin ad soyadını sor.";
    if (phoneDigits.length < 10 || phoneDigits.length > 12) {
      return "HATA: Telefon numarası geçersiz görünüyor. Müşteriden 05xx xxx xx xx biçiminde tekrar iste.";
    }

    const { data, error } = await db.rpc("book_appointment", {
      p_barber_id: barber.id,
      p_service_id: service.id,
      p_starts_at: startsAt,
      p_customer_name: customerName,
      p_customer_phone: rawPhone,
      p_notes: input.notes ? String(input.notes).trim() : null,
    });

    if (error) {
      const friendly = BOOKING_ERRORS[error.message];
      if (friendly) return `HATA: ${friendly}`;
      console.error("book_appointment failed", error);
      return "HATA: Randevu oluşturulamadı. Müşteriyi WhatsApp'a yönlendir.";
    }

    const appt = (data as Array<{ id: string; starts_at: string }> | null)?.[0];
    if (appt?.id) {
      const { error: markError } = await db.rpc("chat_mark_booked", {
        p_session_id: sessionId, p_appointment_id: appt.id,
      });
      if (markError) console.error("chat_mark_booked failed", markError);
    }
    return JSON.stringify({
      durum: "Randevu oluşturuldu",
      hizmet: service.name,
      berber: barber.name,
      zaman: appt ? dateTimeFmt.format(new Date(appt.starts_at)) : null,
      musteri: customerName,
    });
  }

  return `HATA: Bilinmeyen araç: ${name}`;
}

// ============ Gecmisi yeniden kurma ============
type HistoryRow = { role: string; content: string; blocks: unknown };

// DB'deki satirlari Anthropic mesaj dizisine cevirir.
//
// blocks dolu satirlar tam icerik blogudur (tool_use / tool_result dahil) ve
// aynen geri oynatilir. Pencere kirpmasi bir tool_result'i tool_use'undan
// ayirabilecegi icin, bastaki satirlar ilk "duz kullanici metni" bulunana
// kadar atilir — boylece yetim tool_result kalmaz (API 400 verirdi).
function buildMessages(rows: HistoryRow[]): Anthropic.MessageParam[] {
  let start = 0;
  while (start < rows.length && !(rows[start].role === "user" && !rows[start].blocks)) {
    start++;
  }
  if (start >= rows.length) start = rows.length - 1;

  return rows.slice(Math.max(start, 0)).map((r) => ({
    role: r.role === "assistant" ? "assistant" : "user",
    content: (r.blocks ?? r.content) as Anthropic.MessageParam["content"],
  }));
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
  const sessionId = body?.session_id;
  const message = typeof body?.message === "string" ? body.message.trim() : "";

  if (typeof sessionId !== "string" || !/^[0-9a-f-]{36}$/i.test(sessionId)) {
    return json({ error: "invalid_session" }, 400, origin);
  }
  if (!message || message.length > MAX_MESSAGE_LENGTH) {
    return json({ error: "invalid_message" }, 400, origin);
  }

  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) {
    // Teshis: yalnizca secret ADLARI loglanir, degerler asla.
    const names = Object.keys(Deno.env.toObject())
      .filter((k) => !k.startsWith("SUPABASE_") && !k.startsWith("SB_"))
      .sort().join(", ");
    console.error("ANTHROPIC_API_KEY secret ayarlanmamis. Tanimli secret adlari:", names);
    return json({ reply: FALLBACK_REPLY }, 200, origin);
  }

  const db = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  );

  const rawIp = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() || "unknown";
  const ipHash = await hashIp(rawIp);

  // 1) Limit kontrolü + kullanıcı mesajını kaydet + geçmişi al (tek atomik çağrı)
  const { data: historyRows, error: turnError } = await db.rpc("chat_begin_turn", {
    p_session_id: sessionId, p_ip_hash: ipHash, p_message: message,
  });

  if (turnError) {
    const limitReply = LIMIT_REPLIES[turnError.message];
    if (limitReply) {
      return json({ reply: limitReply, limit_reached: true }, 200, origin);
    }
    console.error("chat_begin_turn failed", turnError);
    return json({ reply: FALLBACK_REPLY }, 200, origin);
  }

  const messages = buildMessages((historyRows ?? []) as HistoryRow[]);

  // 2) Claude tool loop
  const client = new Anthropic({ apiKey });
  let reply = "";

  const logTurn = async (role: "assistant" | "tool", content: string, blocks: unknown) => {
    const { error } = await db.rpc("chat_log_turn", {
      p_session_id: sessionId, p_role: role, p_content: content, p_blocks: blocks,
    });
    if (error) console.error("chat_log_turn failed", error);
  };

  try {
    for (let i = 0; i < MAX_TOOL_ITERATIONS; i++) {
      const response = await client.messages.create({
        model: MODEL,
        max_tokens: 2048,
        system: [
          { type: "text", text: SYSTEM_PROMPT, cache_control: { type: "ephemeral" } },
          { type: "text", text: `Bugünün tarihi: ${todayIstanbul()} (Europe/Istanbul).` },
        ],
        tools: TOOLS,
        messages,
      });

      const text = response.content
        .filter((b): b is Anthropic.TextBlock => b.type === "text")
        .map((b) => b.text).join("\n").trim();

      const toolUses = response.content.filter(
        (b): b is Anthropic.ToolUseBlock => b.type === "tool_use",
      );

      // Her turu TAM icerik bloguyla kaydet: bir sonraki istekte
      // tool_use / tool_result ciftleri aynen geri oynatilabilsin.
      await logTurn("assistant", text, response.content);

      if (!toolUses.length) {
        reply = text;
        break;
      }

      messages.push({ role: "assistant", content: response.content });

      const results: Anthropic.ToolResultBlockParam[] = [];
      for (const tool of toolUses) {
        let content: string;
        try {
          content = await runTool(db, sessionId, tool.name, tool.input as Record<string, unknown>);
        } catch (err) {
          console.error("tool failed", tool.name, err);
          content = "HATA: Araç çalıştırılamadı.";
        }
        results.push({ type: "tool_result", tool_use_id: tool.id, content });
      }
      messages.push({ role: "user", content: results });
      await logTurn("tool", toolUses.map((t) => t.name).join(", "), results);
    }
  } catch (err) {
    if (err instanceof Anthropic.AuthenticationError) {
      console.error("ANTHROPIC_API_KEY gecersiz");
    } else if (err instanceof Anthropic.RateLimitError) {
      console.error("Anthropic rate limit");
    } else if (err instanceof Anthropic.APIError) {
      console.error("Anthropic API hatasi", err.status, err.message);
    } else {
      console.error("beklenmeyen hata", err);
    }
    await logTurn("assistant", FALLBACK_REPLY, null);
    return json({ reply: FALLBACK_REPLY }, 200, origin);
  }

  // Dongu arac cagirmaya devam ederken tukendiyse metin uretilmemis olur.
  if (!reply) {
    console.error("tool loop max iterasyona ulasti, metin cevap uretilmedi");
    reply = FALLBACK_REPLY;
    await logTurn("assistant", reply, null);
  }

  return json({ reply }, 200, origin);
});
