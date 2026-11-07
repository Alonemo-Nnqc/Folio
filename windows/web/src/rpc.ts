// The page and the app talk through WebView2 messages (Bridge.cs). In a plain browser (development on a Mac) the mock answers instead.

type Listener = (data: any) => void;
interface Host {
  postMessage(message: unknown): void;
  postMessageWithAdditionalObjects?(message: unknown, objects: ArrayLike<unknown>): void;
  addEventListener(type: "message", listener: (e: MessageEvent) => void): void;
}

const host: Host | undefined = (window as any).chrome?.webview;
export const inHost = !!host;

let nextId = 1;
const waiting = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>();
const listeners = new Map<string, Set<Listener>>();
const requestHandlers = new Map<string, (params: any) => Promise<unknown>>();
let mockCall: ((method: string, params: any) => Promise<any>) | null = null;

export function setMock(call: (method: string, params: any) => Promise<any>) { mockCall = call; }

export function call<T = any>(method: string, params?: unknown): Promise<T> {
  if (!host) return mockCall ? mockCall(method, params) : Promise.reject(new Error("No host"));
  const id = nextId++;
  return new Promise<T>((resolve, reject) => {
    waiting.set(id, { resolve, reject });
    host.postMessage({ id, method, params: params ?? {} });
  });
}

/** Paths of files dropped on the page: WebView2 hands them over only as objects of a message. */
export function droppedPaths(files: FileList): Promise<string[]> {
  if (!host?.postMessageWithAdditionalObjects) return Promise.resolve([]);
  const id = nextId++;
  return new Promise((resolve, reject) => {
    waiting.set(id, { resolve, reject });
    host.postMessageWithAdditionalObjects!({ id, method: "drop.paths", params: {} }, files);
  });
}

export function on(event: string, listener: Listener): () => void {
  let set = listeners.get(event);
  if (!set) listeners.set(event, (set = new Set()));
  set.add(listener);
  return () => set!.delete(listener);
}

export function emitLocal(event: string, data: unknown) { listeners.get(event)?.forEach((l) => l(data)); }

export function handleRequest(method: string, handler: (params: any) => Promise<unknown>) { requestHandlers.set(method, handler); }

host?.addEventListener("message", async (e) => {
  const m = e.data;
  if (m.id !== undefined) {
    const w = waiting.get(m.id);
    waiting.delete(m.id);
    if (m.error !== undefined) w?.reject(new Error(m.error));
    else w?.resolve(m.result);
  } else if (m.event) {
    listeners.get(m.event)?.forEach((l) => l(m.data));
  } else if (m.request !== undefined) {
    const handler = requestHandlers.get(m.method);
    const result = handler ? await handler(m.params) : null;
    host!.postMessage({ reply: m.request, result });
  }
});
