const T = {
  tr: { brand: "Minik Dünya", parents: "Ebeveynler İçin", all: "Hepsi",
    tagline: "Her gün yeni bir macera, güvenle izleyin!",
    sub: "Reklamsız, hesapsız, yorumsuz. 3-6 yaş için eğitici çizgi filmler.",
    footer: "Tüm bölümler yapay zekayla hazırlanır ve yayından önce insan tarafından kontrol edilir.",
    today: "Bugünün Bölümü", learn: "Öğreniyoruz", age: "yaş", soon: "Video yakında burada!" },
  en: { brand: "Little World", parents: "For Parents", all: "All",
    tagline: "A new adventure every day, safe to watch!",
    sub: "No ads, no accounts, no comments. Educational cartoons for ages 3-6.",
    footer: "All episodes are AI-made and checked by a human before release.",
    today: "Today's Episode", learn: "We learn", age: "years", soon: "Video coming soon!" }
};
let lang = localStorage.getItem("lang") || "tr", age = "all", eps = [];

const $ = (s) => document.querySelector(s);
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

function player(e) {
  if (!e.youtube_id) return `<div class="ph">🎬 ${T[lang].soon}</div>`;
  // youtube-nocookie: çerez/takip yok, ilgili videolar kapalı
  return `<iframe src="https://www.youtube-nocookie.com/embed/${encodeURIComponent(e.youtube_id)}?rel=0" title="${esc(e.title[lang])}" allowfullscreen loading="lazy"></iframe>`;
}
function card(e) {
  return `<article class="card"><div class="media">${player(e)}</div>
    <h3>${esc(e.title[lang])}</h3><p>${esc(e.summary[lang])}</p>
    <small>🎯 ${T[lang].learn}: ${esc(e.learning[lang])} · ${esc(e.age)} ${T[lang].age}</small></article>`;
}
function render() {
  document.documentElement.lang = lang;
  document.querySelectorAll("[data-i18n]").forEach((n) => (n.textContent = T[lang][n.dataset.i18n]));
  $("#lang").textContent = lang === "tr" ? "EN" : "TR";
  const pub = eps.filter((e) => e.status === "published").sort((a, b) => b.date.localeCompare(a.date));
  const [latest, ...rest] = pub;
  $("#today").innerHTML = latest ? `<h2>${T[lang].today}</h2>${card(latest)}` : "";
  const list = (age === "all" ? rest : pub.filter((e) => e.age === age));
  $("#list").innerHTML = list.map(card).join("");
}
$("#lang").onclick = () => { lang = lang === "tr" ? "en" : "tr"; try { localStorage.setItem("lang", lang); } catch {} render(); };
document.querySelectorAll(".filters button").forEach((b) => (b.onclick = () => {
  age = b.dataset.age;
  document.querySelectorAll(".filters button").forEach((x) => x.classList.toggle("on", x === b));
  render();
}));
fetch("episodes.json").then((r) => r.json()).then((d) => { eps = d.episodes; render(); });
