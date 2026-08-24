// Gerçek deploy'da bu değer sabit bir string olarak tutuluyor (MCP üzerinden
// `supabase secrets set` çalıştırma imkanı yok). Gerçek değer GIZLI-BILGILER.md'de
// ve Supabase'deki canlı fonksiyon koduna gömülü — bu repo kopyasına yazılmıyor
// çünkü repo public.
const WEBHOOK_SECRET = Deno.env.get("TELEGRAM_WEBHOOK_SECRET") ?? "REPLACE_ME";

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("ok");
  }

  const secretHeader = req.headers.get("x-telegram-bot-api-secret-token");
  if (!WEBHOOK_SECRET || secretHeader !== WEBHOOK_SECRET) {
    return new Response("forbidden", { status: 403 });
  }

  const update = await req.json().catch(() => null);
  const message = update?.message;
  const chatId = message?.chat?.id?.toString();
  const text = message?.text;

  if (chatId && text) {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

    try {
      const resp = await fetch(`${supabaseUrl}/rest/v1/rpc/handle_telegram_command`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "apikey": serviceKey ?? "",
          "Authorization": `Bearer ${serviceKey ?? ""}`,
        },
        body: JSON.stringify({ p_chat_id: chatId, p_text: text }),
      });
      if (!resp.ok) {
        console.error("handle_telegram_command failed", resp.status, await resp.text());
      }
    } catch (err) {
      console.error("rpc call failed", err);
    }
  }

  return new Response("ok");
});
