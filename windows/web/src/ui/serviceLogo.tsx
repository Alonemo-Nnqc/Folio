import { Sparkles } from "lucide-react";

/** Logos drawn in one colour (they follow the text colour); the others keep their brand colours. */
const MONO = new Set(["apple", "clinecli", "copilotcli", "cursoragent", "gooseagent", "grok", "grokcli", "groq", "hermesagent", "kimicli", "lmstudio", "ollama", "openai", "opencode"]);
const KNOWN = new Set([...MONO, "google", "bing", "claudecode", "codex", "geminicli", "qwencode", "antigravitycli", "kirocli", "ampcli", "openclawagent", "deepseekharness",
  "anthropic", "gemini", "deepseek", "aliyundashscope", "qwenmt", "zhipu", "siliconflow", "modelscope", "azureopenai", "deepl", "azure", "tencentmechinetranslation"]);

/** A translation service's official logo; the AI sparkles for those without one. */
export function ServiceLogo({ id, size = 16 }: { id: string; size?: number }) {
  const style = { width: size, height: size };
  if (!KNOWN.has(id)) return <span className="svc-logo" style={style}><Sparkles size={size * 0.85} strokeWidth={1.8} /></span>;
  const url = `services/${id}.svg`;
  return MONO.has(id)
    ? <span className="svc-logo mono" style={{ ...style, WebkitMaskImage: `url(${url})`, maskImage: `url(${url})` }} />
    : <img className="svc-logo" src={url} alt="" style={style} draggable={false} />;
}
