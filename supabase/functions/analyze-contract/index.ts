// supabase/functions/analyze-contract/index.ts
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import * as pdfjsLib from "npm:pdfjs-dist@4.7.76/legacy/build/pdf.mjs";
import { jwtVerify } from "https://deno.land/x/jose@v4.15.5/index.ts";

/* ========= Auth (verify Supabase JWT) ========= */
const JWT_SECRET = Deno.env.get("JWT_SECRET")!;
const enc = new TextEncoder();

async function authUserId(req: Request): Promise<string | null> {
  const hdr = req.headers.get("authorization") ?? "";
  const m = hdr.match(/^Bearer\s+(.+)$/i);
  if (!m) return null;
  try {
   const { payload } = await jwtVerify(m[1], enc.encode(JWT_SECRET), { algorithms: ["HS256"] });
    return (payload.sub as string) ?? null; // Supabase user id
  } catch {
    return null;
  }
}

/* ========= Env ========= */
const AI_PROVIDER = (Deno.env.get("AI_PROVIDER") ?? "gemini").toLowerCase(); // "gemini" | "vertex"
const GEMINI_API_KEY = Deno.env.get("GEMINI_API_KEY") ?? "";
const DEFAULT_MODEL = Deno.env.get("GEMINI_MODEL") ?? "gemini-1.5-flash";

const VERTEX_PROJECT = Deno.env.get("VERTEX_PROJECT") ?? "";
const VERTEX_LOCATION = Deno.env.get("VERTEX_LOCATION") ?? "";
const VERTEX_MODEL = Deno.env.get("VERTEX_MODEL") ?? "gemini-1.5-flash-002";
const VERTEX_SA_KEY_JSON = Deno.env.get("VERTEX_SA_KEY_JSON") ?? "";

const FORCE_DEMO = (Deno.env.get("FORCE_DEMO") ?? "").trim() === "1";

/* ========= CORS ========= */
// Keep permissive while testing. Lock it down later if you want.
// put near the top of index.ts
const ALLOWED_ORIGINS = new Set<string>([
  "https://your-web-domain.com",  // ← your future web app (or keep it if you won’t have web yet)
  "http://localhost:5173",        // dev web
  "capacitor://localhost",        // Capacitor (if you use it)
  "ionic://localhost",            // (optional)
]);

function corsHeaders(req: Request) {
  const origin = req.headers.get("origin");
  // Native apps have no Origin → allow "*"
  const allow = origin && ALLOWED_ORIGINS.has(origin) ? origin : "*";
  return {
    "Access-Control-Allow-Origin": allow,
    "Vary": "Origin",
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type, x-user-id",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
  };
}

function respond(req: Request, body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...corsHeaders(req) },
  });
}

/* ========= utils ========= */
function normalize(s: string) {
  return s
    .replace(/\u0000/g, "")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}
function chunk(s: string, opts: { targetChars: number; overlap: number }) {
  const out: string[] = [];
  let i = 0;
  while (i < s.length) {
    const end = Math.min(i + opts.targetChars, s.length);
    out.push(s.slice(i, end));
    if (end === s.length) break;
    i = Math.max(0, end - opts.overlap);
  }
  return out;
}
const delay = (ms: number) => new Promise((res) => setTimeout(res, ms));
const estTokens = (str: string) => Math.ceil((str?.length ?? 0) / 4);
const jitter = (m = 0.3) => 1 - m + Math.random() * (2 * m);

/* ========= PDF extraction ========= */
async function extractPdfText(
  bytes: Uint8Array,
  pageCap: number
): Promise<{ text: string; pages: number }> {
  const loadingTask = pdfjsLib.getDocument({ data: bytes });
  const pdf = await loadingTask.promise;
  const parts: string[] = [];
  const maxPage = Math.min(pdf.numPages, pageCap);
  for (let p = 1; p <= maxPage; p++) {
    const page = await pdf.getPage(p);
    const content = await page.getTextContent();
    const text = content.items
      .map((it: any) => ("str" in it ? it.str : ""))
      .join(" ");
    parts.push(text);
  }
  return { text: parts.join("\n\n"), pages: pdf.numPages };
}

/* ========= Risk helpers ========= */
function clampScore(n: number) {
  if (!Number.isFinite(n)) return 0;
  return Math.max(0, Math.min(100, Math.round(n)));
}
function weightForSeverity(s: string) {
  switch ((s || "").toLowerCase()) {
    case "high":
      return 25;
    case "medium":
      return 15;
    case "low":
      return 8;
    default:
      return 12;
  }
}
function riskLabelFor(score: number) {
  if (score >= 85) return "Safe to sign (low risk)";
  if (score >= 70) return "Mostly OK (minor fixes)";
  if (score >= 55) return "Caution (needs changes)";
  if (score >= 40) return "Risky (major changes)";
  return "Do not sign as-is";
}
type ProCon = { title: string; why_it_matters: string };
type RedFlag = {
  clause: string;
  severity: "low" | "medium" | "high";
  explanation: string;
  suggested_language: string;
  source_excerpt?: string;
};
type KeyClause = { name: string; found: boolean; excerpt: string };
type Out = {
  summary: string;
  pros: ProCon[];
  cons: ProCon[];
  red_flags: RedFlag[];
  key_clauses: KeyClause[];
  questions_for_counterparty: string[];
  negotiation_levers: string[];
  risk_score?: number;
  risk_label?: string;
};
function computeRiskFallback(
  pros: ProCon[],
  cons: ProCon[],
  red_flags: RedFlag[]
) {
  let score = 70;
  score += (pros?.length ?? 0) * 4;
  score -= (cons?.length ?? 0) * 4;
  for (const f of red_flags ?? []) score -= weightForSeverity(f.severity);
  const finalScore = clampScore(score);
  return { risk_score: finalScore, risk_label: riskLabelFor(finalScore) };
}
function safeStr(v: unknown): string {
  if (!v) return "";
  try {
    if (typeof v === "string") return v;
    return JSON.stringify(v);
  } catch {
    return String(v);
  }
}
function haystackFrom(out: Out): string {
  const parts: string[] = [];
  parts.push(out.summary ?? "");
  for (const p of out.pros ?? [])
    parts.push(p.title ?? "", p.why_it_matters ?? "");
  for (const c of out.cons ?? [])
    parts.push(c.title ?? "", c.why_it_matters ?? "");
  for (const rf of out.red_flags ?? [])
    parts.push(
      rf.clause ?? "",
      rf.explanation ?? "",
      rf.suggested_language ?? "",
      rf.source_excerpt ?? ""
    );
  for (const kc of out.key_clauses ?? [])
    parts.push(kc.name ?? "", safeStr(kc.excerpt ?? ""));
  for (const q of out.questions_for_counterparty ?? []) parts.push(q);
  for (const n of out.negotiation_levers ?? []) parts.push(n);
  return parts.join(" \n ").toLowerCase();
}
function applyHardRiskRules(out: Out, inputScore: number) {
  let score = inputScore;
  const text = haystackFrom(out);
  const has100ToManager =
    /100\s*%/.test(text) &&
    /(manager|management|label|company)/.test(text) &&
    /(income|earnings|revenue|revenues|proceeds|gross|net)/.test(text);
  const perpetualAllRights =
    /(assigns?|transfers?).{0,40}(all|entire).{0,15}(rights|masters|copyright|ownership).{0,40}(perpetuity|in\s+perpetuity|irrevocable)/.test(
      text
    );
  const manyHighFlags =
    (out.red_flags ?? []).filter(
      (r) => (r.severity ?? "").toLowerCase() === "high"
    ).length >= 3;
  if (has100ToManager) score = Math.min(score, 10);
  if (perpetualAllRights) score = Math.min(score, 20);
  if (manyHighFlags) score = Math.min(score, 30);
  return clampScore(score);
}

/* ========= Schema & Prompts ========= */
const responseSchema = {
  type: "object",
  properties: {
    summary: { type: "string" },
    pros: {
      type: "array",
      items: {
        type: "object",
        properties: { title: { type: "string" }, why_it_matters: { type: "string" } },
        required: ["title", "why_it_matters"],
      },
    },
    cons: {
      type: "array",
      items: {
        type: "object",
        properties: { title: { type: "string" }, why_it_matters: { type: "string" } },
        required: ["title", "why_it_matters"],
      },
    },
    red_flags: {
      type: "array",
      items: {
        type: "object",
        properties: {
          clause: { type: "string" },
          severity: { type: "string", enum: ["low", "medium", "high"] },
          explanation: { type: "string" },
          suggested_language: { type: "string" },
          source_excerpt: { type: "string" },
        },
        required: ["clause", "severity", "explanation", "suggested_language"],
      },
    },
    key_clauses: {
      type: "array",
      items: {
        type: "object",
        properties: { name: { type: "string" }, found: { type: "boolean" }, excerpt: { type: "string" } },
        required: ["name", "found", "excerpt"],
      },
    },
    questions_for_counterparty: { type: "array", items: { type: "string" } },
    negotiation_levers: { type: "array", items: { type: "string" } },
    risk_score: { type: "integer", minimum: 0, maximum: 100 },
    risk_label: { type: "string" },
  },
  required: [
    "summary",
    "pros",
    "cons",
    "red_flags",
    "key_clauses",
    "questions_for_counterparty",
    "negotiation_levers",
  ],
} as const;

function chunkPrompt(txt: string) {
  return `You are helping a MUSIC MANAGER who hates legal jargon.
Analyze ONLY the excerpt and return STRICT JSON that matches the schema.

STYLE:
- Year-7 reading level. Max 12 words per sentence.
- Everyday words only: deal, payment, ending, fix, promise, owns, share, deadline, refund.
- Avoid words: clause, indemnify, perpetual, herein, pursuant, assignor/assignee, liability.
- Keep everything short: 1–2 sentences each.
- Pros/Cons titles: 3–6 words.
- red_flags.clause = short headline like "Label owns your songs".
- Each red flag must include "source_excerpt": a direct quote (≤30 words) copied from the contract that triggered it.
- Prefer numbers over vague words. If missing, suggest a range (e.g., "15–20%", "30–60 days").

SUMMARY:
- 2–3 short sentences. Friendly, plain English. No recommendations.

TOP RECOMMENDATION:
- Put your single best numeric recommendation as the FIRST item in negotiation_levers.

RISK SCORING:
- Start at 70. Each red flag: -25 (high), -15 (medium), -8 (low). Each con: -4. Each pro: +4.
- Clamp 0–100. Map to labels.

Return STRICT JSON only.

EXCERPT:
"""${txt}"""`;
}
function reducerPrompt(parts: Out[]) {
  return `Merge these partial analyses for ONE contract into a single final JSON.
- Year-7 reading level; dedupe similar points; prefer numbers.
- First negotiation_levers item must be one clear numeric ask.
- Recalculate risk using the same rule.
Return STRICT JSON only.
PARTIALS:
${JSON.stringify(parts)}`;
}

/* ========= Budget & Modes ========= */
const BUDGET_MONTH_USD = Number(Deno.env.get("BUDGET_MONTH_USD") ?? "20");
const PRICE = { inputPerM: 0.30, outputPerM: 2.50 };
let MODE = Deno.env.get("MODE") ?? "normal";
const POLICY: Record<
  string,
  {
    maxPages: number;
    maxBytes: number;
    chunkChars: number;
    chunkOverlap: number;
    delayMs: number;
    maxOutputTokens: number;
    perUserDailyAnalyses: number;
    perUserConcurrency: number;
    model: string;
  }
> = {
  normal: {
    maxPages: 50,
    maxBytes: 10 * 1024 * 1024,
    chunkChars: 5000,
    chunkOverlap: 500,
    delayMs: 700,
    maxOutputTokens: 1200,
    perUserDailyAnalyses: 50,
    perUserConcurrency: 2,
    model: DEFAULT_MODEL,
  },
  light: {
    maxPages: 25,
    maxBytes: 5 * 1024 * 1024,
    chunkChars: 4000,
    chunkOverlap: 400,
    delayMs: 1200,
    maxOutputTokens: 700,
    perUserDailyAnalyses: 25,
    perUserConcurrency: 1,
    model: "gemini-1.5-flash",
  },
  critical: {
    maxPages: 10,
    maxBytes: 2 * 1024 * 1024,
    chunkChars: 3000,
    chunkOverlap: 300,
    delayMs: 2000,
    maxOutputTokens: 400,
    perUserDailyAnalyses: 10,
    perUserConcurrency: 1,
    model: "gemini-1.5-flash-lite",
  },
};
type Usage = { calls: number; tokensIn: number; tokensOut: number; month: string };
const globalUsage: Usage = { calls: 0, tokensIn: 0, tokensOut: 0, month: monthKey() };
const perUserDaily = new Map<string, { date: string; count: number; active: number }>();
let globalActive = 0;
const GLOBAL_MAX_ACTIVE = 3;

function monthKey(d = new Date()) {
  return `${d.getUTCFullYear()}-${(d.getUTCMonth() + 1)
    .toString()
    .padStart(2, "0")}`;
}
function dateKey(d = new Date()) {
  return d.toISOString().slice(0, 10);
}
function rotateMonthIfNeeded() {
  const mk = monthKey();
  if (globalUsage.month !== mk) {
    globalUsage.calls = 0;
    globalUsage.tokensIn = 0;
    globalUsage.tokensOut = 0;
    globalUsage.month = mk;
    MODE = Deno.env.get("MODE") || "normal";
  }
}
function budgetPct() {
  const cost =
    (globalUsage.tokensIn / 1e6) * PRICE.inputPerM +
    (globalUsage.tokensOut / 1e6) * PRICE.outputPerM;
  return Math.min(100, (cost / BUDGET_MONTH_USD) * 100);
}
function underMonthlyBudget() {
  rotateMonthIfNeeded();
  const cost =
    (globalUsage.tokensIn / 1e6) * PRICE.inputPerM +
    (globalUsage.tokensOut / 1e6) * PRICE.outputPerM;
  return cost < BUDGET_MONTH_USD;
}
function maybeAutoMode() {
  if (Deno.env.get("MODE")) return;
  const pct = budgetPct();
  if (pct >= 75) MODE = "critical";
  else if (pct >= 50) MODE = "light";
  else MODE = "normal";
}
function getUserKey(req: Request): string {
  const uid = req.headers.get("x-user-id");
  if (uid) return `user:${uid}`;
  const ip =
    (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() ||
    "unknown";
  return `anon:${ip}`;
}
function takePerUserSlot(userKey: string, mode: string) {
  const today = dateKey();
  const rec = perUserDaily.get(userKey) ?? {
    date: today,
    count: 0,
    active: 0,
  };
  if (rec.date !== today) {
    rec.date = today;
    rec.count = 0;
    rec.active = 0;
  }
  const cap = POLICY[mode].perUserDailyAnalyses;
  if (rec.count >= cap) return { ok: false, reason: "daily_cap" as const };
  if (rec.active >= POLICY[mode].perUserConcurrency)
    return { ok: false, reason: "busy" as const };
  rec.count += 1;
  rec.active += 1;
  perUserDaily.set(userKey, rec);
  return { ok: true as const };
}
function releasePerUserSlot(userKey: string) {
  const rec = perUserDaily.get(userKey);
  if (rec) {
    rec.active = Math.max(0, rec.active - 1);
    perUserDaily.set(userKey, rec);
  }
}

/* ========= Simple cache ========= */
const cache = new Map<string, { text: string; expires: number }>();
function cacheGet(key: string) {
  const v = cache.get(key);
  if (!v) return null;
  if (Date.now() > v.expires) {
    cache.delete(key);
    return null;
  }
  return v.text;
}
function cacheSet(key: string, text: string, ttlMs = 24 * 60 * 60 * 1000) {
  cache.set(key, { text, expires: Date.now() + ttlMs });
}
function djb2HashBytes(bytes: Uint8Array) {
  let h = 5381;
  for (let i = 0; i < bytes.length; i++) h = (h << 5) + h + bytes[i];
  return (h >>> 0).toString(16);
}

/* ========= JSON fence helper ========= */
function parseStrictJsonOrThrow(s: string) {
  let txt = String(s ?? "");
  const m = txt.match(/```json\s*([\s\S]*?)```/i);
  if (m) txt = m[1];
  return JSON.parse(txt);
}

/* ========= Provider calls ========= */
async function callGemini(opts: {
  prompt: string;
  schema: unknown;
  maxOutputTokens: number;
  model: string;
}): Promise<{ out: Out; tokensIn: number; tokensOut: number }> {
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${opts.model}:generateContent?key=${GEMINI_API_KEY}`;
  const body = {
    contents: [{ role: "user", parts: [{ text: opts.prompt }] }],
    generationConfig: {
      temperature: 0.2,
      maxOutputTokens: opts.maxOutputTokens,
      responseMimeType: "application/json",
      responseSchema: opts.schema,
    },
  };
  const tokensInEst = estTokens(opts.prompt);

  const maxAttempts = 4;
  let lastErr: unknown = null;

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    const r = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(60000),
    });
    if (r.ok) {
      const j = await r.json();
      const text = j.candidates?.[0]?.content?.parts?.[0]?.text ?? "";
      const parsed = parseStrictJsonOrThrow(text) as Out;
      const tokensOutEst = estTokens(JSON.stringify(parsed));
      return { out: parsed, tokensIn: tokensInEst, tokensOut: tokensOutEst };
    }
    const txt = await r.text();
    lastErr = new Error(`${r.status} ${txt}`);
    if ((r.status === 429 || r.status === 503 || r.status === 500) && attempt < maxAttempts) {
      const wait = Math.min(15000, Math.round(600 * Math.pow(2, attempt - 1) * jitter(0.3)));
      await delay(wait);
      continue;
    }
    break;
  }
  throw new Error(`Gemini failed after retries: ${String(lastErr)}`);
}

async function getVertexAccessToken(
  saKeyJson: string,
  scope = "https://www.googleapis.com/auth/cloud-platform"
) {
  const sa = JSON.parse(saKeyJson);
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "RS256", typ: "JWT" };
  const claimSet = {
    iss: sa.client_email,
    scope,
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  };
  const enc2 = (obj: unknown) =>
    b64url(new TextEncoder().encode(JSON.stringify(obj)));
  const unsigned = `${enc2(header)}.${enc2(claimSet)}`;
  const keyData = pemToPkcs8(sa.private_key);
  const cryptoKey = await crypto.subtle.importKey(
    "pkcs8",
    keyData,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const sig = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    cryptoKey,
    new TextEncoder().encode(unsigned)
  );
  const jwt = `${unsigned}.${b64url(new Uint8Array(sig))}`;
  const form = new URLSearchParams();
  form.set("grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer");
  form.set("assertion", jwt);
  const resp = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: form.toString(),
    signal: AbortSignal.timeout(60000),
  });
  if (!resp.ok)
    throw new Error(
      `Vertex token exchange failed: ${resp.status} ${await resp.text()}`
    );
  const j = await resp.json();
  return j.access_token as string;
}
function pemToPkcs8(pem: string) {
  const b64 = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const raw = atob(b64);
  const arr = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) arr[i] = raw.charCodeAt(i);
  return arr.buffer;
}
function b64url(bytes: Uint8Array) {
  let s = "";
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
async function callVertex(opts: {
  prompt: string;
  schema: unknown;
  maxOutputTokens: number;
  model: string;
}): Promise<{ out: Out; tokensIn: number; tokensOut: number }> {
  if (!VERTEX_PROJECT || !VERTEX_LOCATION || !VERTEX_SA_KEY_JSON) {
    throw new Error(
      "Vertex not configured: set VERTEX_PROJECT, VERTEX_LOCATION, VERTEX_SA_KEY_JSON."
    );
  }
  const accessToken = await getVertexAccessToken(VERTEX_SA_KEY_JSON);
  const modelPath = `projects/${VERTEX_PROJECT}/locations/${VERTEX_LOCATION}/publishers/google/models/${opts.model}`;
  const url = `https://${VERTEX_LOCATION}-aiplatform.googleapis.com/v1/${modelPath}:generateContent`;
  const body = {
    contents: [{ role: "user", parts: [{ text: opts.prompt }] }],
    generationConfig: {
      temperature: 0.2,
      maxOutputTokens: opts.maxOutputTokens,
      responseMimeType: "application/json",
      responseSchema: opts.schema,
    },
  };
  const tokensInEst = estTokens(opts.prompt);

  const maxAttempts = 4;
  let lastErr: unknown = null;

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    const r = await fetch(url, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${accessToken}`,
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(60000),
    });
    if (r.ok) {
      const j = await r.json();
      const text = j.candidates?.[0]?.content?.parts?.[0]?.text ?? "";
      const parsed = parseStrictJsonOrThrow(text) as Out;
      const tokensOutEst = estTokens(JSON.stringify(parsed));
      return { out: parsed, tokensIn: tokensInEst, tokensOut: tokensOutEst };
    }
    const errTxt = await r.text();
    lastErr = new Error(`${r.status} ${errTxt}`);
    if (r.status === 400 && /unexpected model name format/i.test(errTxt)) {
      throw new Error(
        `Vertex error 400: unexpected model name format. Use short VERTEX_MODEL like "gemini-1.5-flash-002".`
      );
    }
    if ((r.status === 429 || r.status === 503 || r.status === 500) && attempt < maxAttempts) {
      const wait = Math.min(15000, Math.round(600 * Math.pow(2, attempt - 1) * jitter(0.3)));
      await delay(wait);
      continue;
    }
    break;
  }
  throw new Error(`Vertex failed after retries: ${String(lastErr)}`);
}

/* ========= HTTP ========= */
serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders(req) });
  }

  // Require a valid Supabase access token
  const tokenUserId = await authUserId(req);
  if (!tokenUserId) {
    return respond(req, { ok: false, error: "Unauthorized" }, 401);
  }

  // Optional: also enforce x-user-id to match if you still send it
  const headerUserId = (req.headers.get("x-user-id") ?? "").trim();
  if (headerUserId && headerUserId !== tokenUserId) {
    return respond(req, { ok: false, error: "Unauthorized (mismatch)" }, 401);
  }

  const verifiedUserKey = `user:${tokenUserId}`;

  rotateMonthIfNeeded();
  maybeAutoMode();
  const policy = POLICY[MODE];

  try {
    const body = await req.json().catch(() => ({}));
    const fileUrl: string | undefined = body.fileUrl;
    const demoReq: boolean = !!body.demo;

    // Demo path
    if (demoReq || FORCE_DEMO || (AI_PROVIDER === "gemini" && !GEMINI_API_KEY)) {
      const demo: Out = {
        summary: "Demo only. This is not legal advice.",
        pros: [{ title: "✅ Clear scope", why_it_matters: "You know what is covered." }],
        cons: [{ title: "⚠️ One-sided term", why_it_matters: "Gives them too much control." }],
        red_flags: [
          {
            clause: "Manager gets 100% of artist income",
            severity: "high",
            explanation: "You keep no earnings. This is unfair.",
            suggested_language: "Set commission to 15–20%, not 100%.",
            source_excerpt: "Manager shall receive 100% of Artist’s income from all sources.",
          },
          {
            clause: "All rights in perpetuity",
            severity: "high",
            explanation: "Rights never return. You lose control.",
            suggested_language: "Add a 5–7 year reversion of rights.",
            source_excerpt: "Artist hereby assigns all rights in perpetuity.",
          },
        ],
        key_clauses: [
          { name: "Commission", found: true, excerpt: "100% to Manager" },
          { name: "Term", found: true, excerpt: "Initial period 4 years" },
        ],
        questions_for_counterparty: ["Can we set commission to 15–20% instead of 100%?"],
        negotiation_levers: ["Set commission at 15–20%.", "Add reversion after 5–7 years."],
      };
      const fb = computeRiskFallback(demo.pros, demo.cons, demo.red_flags);
      const adjusted = applyHardRiskRules(demo, fb.risk_score!);
      const result: Out = { ...demo, risk_score: adjusted, risk_label: riskLabelFor(adjusted) };
      return respond(req, { ok: true, result, mode: MODE, demo: true });
    }

    if (!fileUrl || !/^https?:\/\//i.test(fileUrl)) {
      return respond(req, { ok: false, error: "Missing or invalid fileUrl (must be a presigned URL)" }, 400);
    }

    if (!underMonthlyBudget()) {
      return respond(req, { ok: false, error: "Monthly budget reached. Please try again next month.", mode: MODE }, 402);
    }

    const slot = takePerUserSlot(verifiedUserKey, MODE);
    if (!slot.ok) {
      const msg =
        slot.reason === "daily_cap"
          ? "Daily limit reached. Try tomorrow."
          : "Another analysis in progress. Please wait.";
      return respond(req, { ok: false, error: msg, mode: MODE }, 429);
    }
    if (globalActive >= GLOBAL_MAX_ACTIVE) {
      releasePerUserSlot(verifiedUserKey);
      return respond(req, { ok: false, error: "Server busy. Please try again shortly.", mode: MODE }, 429);
    }
    globalActive++;

    // Fetch the file
    const f = await fetch(fileUrl, { method: "GET", signal: AbortSignal.timeout(30000) });
    if (!f.ok) throw new Error(`Fetch failed: ${f.status}`);
    const contentType = (f.headers.get("content-type") ?? "").toLowerCase();
    const contentLength = Number(f.headers.get("content-length") ?? "0");
    const ALLOWED_TYPES = ["application/pdf", "text/plain", "application/octet-stream"];
    if (!ALLOWED_TYPES.some((t) => contentType.includes(t))) {
      globalActive--;
      releasePerUserSlot(verifiedUserKey);
      return respond(req, { ok: false, error: `Unsupported content-type: ${contentType}`, mode: MODE }, 415);
    }
    if (contentLength && contentLength > policy.maxBytes) {
      globalActive--;
      releasePerUserSlot(verifiedUserKey);
      return respond(req, { ok: false, error: `File too large for ${MODE} mode.`, mode: MODE }, 413);
    }

    const bytes = new Uint8Array(await f.arrayBuffer());
    if (bytes.length > policy.maxBytes) {
      globalActive--;
      releasePerUserSlot(verifiedUserKey);
      return respond(req, { ok: false, error: `File too large for ${MODE} mode.`, mode: MODE }, 413);
    }

    // Extract text
    const urlLower = fileUrl.toLowerCase();
    const looksLikePdf =
      contentType.includes("pdf") ||
      (contentType.includes("octet-stream") && urlLower.includes(".pdf"));
    let rawText = "";
    let totalPages = 0;
    if (looksLikePdf) {
      const { text, pages } = await extractPdfText(bytes, policy.maxPages);
      totalPages = pages;
      rawText =
        pages > policy.maxPages
          ? text + `\n\n[Truncated after ${policy.maxPages} pages due to ${MODE} mode]`
          : text;
    } else if (contentType.startsWith("text/") || urlLower.endsWith(".txt")) {
      rawText = new TextDecoder().decode(bytes);
      totalPages = 1;
    } else {
      globalActive--;
      releasePerUserSlot(verifiedUserKey);
      return respond(
        req,
        { ok: false, error: `Unsupported file type. content-type=${contentType} url=${fileUrl}`, mode: MODE },
        415
      );
    }

    const text = normalize(rawText);
    if (text.length < 80) {
      globalActive--;
      releasePerUserSlot(verifiedUserKey);
      return respond(req, { ok: false, error: "No meaningful text extracted.", mode: MODE }, 400);
    }

    // Chunk + analyze
    const fileHash = djb2HashBytes(bytes);
    const chunks = chunk(text, { targetChars: policy.chunkChars, overlap: policy.chunkOverlap });

    const partials: Out[] = [];
    let tokensInSum = 0,
      tokensOutSum = 0;

    const callProvider = async (prompt: string, maxOut: number) => {
      if (AI_PROVIDER === "vertex") {
        return await callVertex({
          prompt,
          schema: responseSchema,
          maxOutputTokens: maxOut,
          model: VERTEX_MODEL,
        });
      }
      return await callGemini({
        prompt,
        schema: responseSchema,
        maxOutputTokens: maxOut,
        model: policy.model,
      });
    };

    for (const [i, c] of chunks.entries()) {
      const ck = `${fileHash}:chunk:${i}:prov:${AI_PROVIDER}:model:${
        AI_PROVIDER === "vertex" ? VERTEX_MODEL : policy.model
      }:oot:${policy.maxOutputTokens}`;
      const cached = cacheGet(ck);
      if (cached) {
        try {
          const parsed = JSON.parse(cached) as Out;
          partials.push(parsed);
          tokensOutSum += estTokens(cached);
          continue;
        } catch {
          /* ignore bad cache */
        }
      }
      if (i > 0) await delay(Math.round(policy.delayMs * jitter(0.3)));
      const { out, tokensIn, tokensOut } = await callProvider(
        chunkPrompt(c),
        policy.maxOutputTokens
      );
      tokensInSum += tokensIn;
      tokensOutSum += tokensOut;
      partials.push(out);
      cacheSet(ck, JSON.stringify(out));
    }

    // Merge
    const mergeKey = `${fileHash}:merge:prov:${AI_PROVIDER}:model:${
      AI_PROVIDER === "vertex" ? VERTEX_MODEL : policy.model
    }:oot:${Math.max(policy.maxOutputTokens, 1200)}`;
    let merged: Out;
    const cachedMerge = cacheGet(mergeKey);
    if (cachedMerge) {
      merged = JSON.parse(cachedMerge) as Out;
      tokensOutSum += estTokens(cachedMerge);
    } else {
      if (chunks.length > 1) await delay(Math.round(policy.delayMs * jitter(0.3)));
      const mergedCall = await callProvider(
        reducerPrompt(partials),
        Math.max(policy.maxOutputTokens, 1200)
      );
      merged = mergedCall.out;
      tokensInSum += mergedCall.tokensIn;
      tokensOutSum += mergedCall.tokensOut;
      cacheSet(mergeKey, JSON.stringify(merged));
    }

    // Risk finalize
    let result: Out = { ...merged };
    if (typeof result.risk_score !== "number") {
      const fb = computeRiskFallback(
        result.pros ?? [],
        result.cons ?? [],
        result.red_flags ?? []
      );
      result.risk_score = fb.risk_score;
      result.risk_label = fb.risk_label;
    } else {
      result.risk_score = clampScore(result.risk_score);
      result.risk_label = result.risk_label ?? riskLabelFor(result.risk_score);
    }
    const adjusted = applyHardRiskRules(result, result.risk_score!);
    result.risk_score = adjusted;
    result.risk_label = riskLabelFor(adjusted);

    // usage + mode
    globalUsage.calls += 1;
    globalUsage.tokensIn += tokensInSum;
    globalUsage.tokensOut += tokensOutSum;
    maybeAutoMode();
    globalActive--;
    releasePerUserSlot(verifiedUserKey);

    const costNow =
      (globalUsage.tokensIn / 1e6) * PRICE.inputPerM +
      (globalUsage.tokensOut / 1e6) * PRICE.outputPerM;
    const budgetWarn =
      costNow >= BUDGET_MONTH_USD ? "Budget reached after this request." : undefined;

    return respond(req, {
      ok: true,
      result,
      mode: MODE,
      provider: AI_PROVIDER,
      budget_pct: Math.round(budgetPct()),
      budget_warn: budgetWarn,
      total_pages: totalPages,
    });
  } catch (e) {
    globalActive--; // safety
    releasePerUserSlot(verifiedUserKey);
    console.error(e);
    return respond(
      req,
      { ok: false, error: String(e), provider: AI_PROVIDER, mode: MODE },
      500
    );
  }
});
