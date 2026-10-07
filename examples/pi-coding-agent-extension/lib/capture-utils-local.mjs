// Local fork additions to the shared capture library.
//
// `shared/capture-utils.mjs` is generated from examples/memory-plugin-shared/lib
// and used by every memory plugin. The two rules below apply to this extension
// only, so they wrap the shared module here instead of changing it:
//
// - `captureMode: "keyword"` keeps a turn only when it carries a durable-memory
//   trigger. The shared schema declares the knob; the shared library does not
//   act on it.
// - Tool inputs and tool outputs have common credential fields and values
//   redacted before they leave the process.
import {
  extractPartsFromPayload as sharedExtractPartsFromPayload,
  shapeCapturePayload as sharedShapeCapturePayload,
  shouldCaptureText as sharedShouldCaptureText,
} from "../shared/capture-utils.mjs";

export {
  extractTextFromPayload,
  sanitizeCapturedText,
  truncateCaptureText,
} from "../shared/capture-utils.mjs";

const MEMORY_TRIGGERS = [
  /remember|preference|prefer|important|decision|decided|always|never/i,
  /[\w.-]+@[\w.-]+\.\w+/,
  /(?:my)\s*(?:name|live|from|birthday|phone|email)/i,
  /(?:i)\s*(?:like|hate|love|want|need|think|believe)/i,
  /(?:favorite|favourite|love|hate|enjoy|dislike)/i,
];

const SENSITIVE_FIELD_RE = /^(?:authorization|api[_-]?key|token|access[_-]?token|refresh[_-]?token|secret|password|passwd|credential|cookie|private[_-]?key|root[_-]?api[_-]?key)$/i;

export function redactSensitiveString(value) {
  return String(value || "")
    .replace(/(\bBearer\s+)[A-Za-z0-9._~+/=-]+/gi, "$1[REDACTED]")
    .replace(/((?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|password|passwd|credential|private[_-]?key|root[_-]?api[_-]?key)\s*(?:=|:)\s*)(?:"[^"]*"|'[^']*'|[^\s,;]+)/gi, "$1[REDACTED]")
    .replace(/((?:--api-key|--token|--password|--secret)\s+)(?:"[^"]*"|'[^']*'|\S+)/gi, "$1[REDACTED]");
}

export function redactSensitive(value, key = "", seen = new WeakSet()) {
  if (SENSITIVE_FIELD_RE.test(String(key || ""))) return "[REDACTED]";
  if (typeof value === "string") return redactSensitiveString(value);
  if (value == null || typeof value !== "object") return value;
  if (seen.has(value)) return "[CIRCULAR]";
  seen.add(value);
  if (Array.isArray(value)) {
    const out = value.map((item) => redactSensitive(item, "", seen));
    seen.delete(value);
    return out;
  }
  const out = {};
  for (const [childKey, childValue] of Object.entries(value)) {
    out[childKey] = redactSensitive(childValue, childKey, seen);
  }
  seen.delete(value);
  return out;
}

/** The shared extractor, with credentials redacted from every tool part. */
export function extractPartsFromPayload(payload, options = {}) {
  return sharedExtractPartsFromPayload(payload, options).map((part) => {
    if (part?.type !== "tool") return part;
    const out = { ...part };
    if (out.tool_input !== undefined) out.tool_input = redactSensitive(out.tool_input);
    if (typeof out.tool_output === "string") out.tool_output = redactSensitiveString(out.tool_output);
    return out;
  });
}

/** Keep shared conversation filters, then apply the local tool and keyword policy. */
export function shapeCapturePayload(payload, role, cfg = {}, options = {}) {
  const shaped = sharedShapeCapturePayload(payload, role, cfg, options);
  if (shaped.dropped) return shaped;
  const parts = shaped.parts
    .filter((part) => cfg.captureToolResults === true ||
      !(part?.type === "tool" && Object.hasOwn(part, "tool_output")))
    .map((part) => {
      if (part?.type !== "tool") return part;
      const out = { ...part };
      if (out.tool_input !== undefined) out.tool_input = redactSensitive(out.tool_input);
      if (typeof out.tool_output === "string") out.tool_output = redactSensitiveString(out.tool_output);
      return out;
    });
  const text = shaped.parts.length && !parts.some((part) => part?.type === "text")
    ? ""
    : shaped.text;
  if (!options.faithful && cfg.captureMode === "keyword" &&
      !shouldCaptureText(text, role, cfg, { filters: false }).shouldCapture) {
    return { ...shaped, parts: [], text: "", signalText: "", dropped: true };
  }
  return { ...shaped, parts, text };
}

/** The shared capture decision, plus the keyword gate of `captureMode: "keyword"`. */
export function shouldCaptureText(text, role, cfg = {}, options) {
  const decision = sharedShouldCaptureText(text, role, cfg, options);
  if (!decision.shouldCapture || cfg.captureMode !== "keyword") return decision;
  const compact = String(decision.text || "").replace(/\s+/g, " ").trim();
  if (!MEMORY_TRIGGERS.some((re) => re.test(compact))) {
    return { shouldCapture: false, reason: "no_trigger", text: "" };
  }
  return { ...decision, reason: "trigger_matched" };
}
