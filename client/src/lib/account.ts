// 账号服务（account-api）的客户端：登录、拉同账号的设备列表、按需取配对码、上报本机。
//
// 和"我的设备"的区别：我的设备存在本机 config.toml 里，只有这台电脑知道；账号设备存在账户服务器上，
// 同一账号的每台设备都看得到。登录之后，"我的设备"照旧可用，账号设备是上面多出来的一块。
//
// 地址：构建时由 VITE_AIRHAND_ACCOUNT_API 注进去（见 .github/workflows/build-airhand.yml），
// 登录页里也能改（存在 localStorage）：内网换 IP 不用重新打包。
// token：account-api 自签的 HMAC token，永不过期；退出登录就是删掉它。
//
// 服务端接口见 account-api/README.md：/auth/login、/device/register、/device/heartbeat、
// /device/list、/device/credential。
import { invoke, isTauri } from "@tauri-apps/api/core";

const BASE_KEY = "airhand.account.base";
const TOKEN_KEY = "airhand.account.token";
const USER_KEY = "airhand.account.user";
const UUID_KEY = "airhand.account.uuid";

/** 构建时注入的默认地址（没有配置就是空字符串，用户得在登录页里填） */
export const BUILTIN_BASE = String(import.meta.env.VITE_AIRHAND_ACCOUNT_API ?? "").replace(/\/+$/, "");

function read(key: string): string | null {
  try {
    return globalThis.localStorage?.getItem(key) ?? null;
  } catch {
    return null;
  }
}

function write(key: string, value: string | null) {
  try {
    if (value === null) globalThis.localStorage?.removeItem(key);
    else globalThis.localStorage?.setItem(key, value);
  } catch {
    // 存不了（例如浏览器禁用了存储）：只在这次有效
  }
}

/** 账号服务器地址，结尾不带 / */
export const baseUrl = () => (read(BASE_KEY) ?? BUILTIN_BASE).replace(/\/+$/, "");

/** 改服务器地址（登录页用）。传空就是回到构建时注入的那个 */
export function setBaseUrl(url: string) {
  write(BASE_KEY, url.trim().replace(/\/+$/, "") || null);
}

export const token = () => read(TOKEN_KEY);
export const currentUser = () => read(USER_KEY);

/** 已经登录（有 token 且知道连哪儿） */
export const loggedIn = () => !!token() && !!baseUrl();

/** 本机在账号服务里的 id：一次生成，永久复用（只是主键，不是密钥） */
export function deviceUuid(): string {
  let id = read(UUID_KEY);
  if (!id) {
    id = newUuid();
    write(UUID_KEY, id);
  }
  return id;
}

/**
 * randomUUID 只在安全上下文（https / localhost / WebView）里有；网页版用 http://内网IP 打开时
 * 它是 undefined，所以留一个手搓的兜底。
 */
function newUuid(): string {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") return crypto.randomUUID();
  const bytes = new Uint8Array(16);
  if (typeof crypto !== "undefined" && crypto.getRandomValues) crypto.getRandomValues(bytes);
  else for (let i = 0; i < 16; i++) bytes[i] = Math.floor(Math.random() * 256);
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

// ───────────────────────── 错误 ─────────────────────────

export type AccountErrorKind = "noServer" | "network" | "unauthorized" | "notFound" | "server";

/** 账号服务的错。`kind` 给界面用（按当前语言显示），`detail` 是技术信息 */
export class AccountError extends Error {
  readonly kind: AccountErrorKind;
  readonly status: number;

  constructor(kind: AccountErrorKind, detail: string, status = 0) {
    super(detail);
    this.name = "AccountError";
    this.kind = kind;
    this.status = status;
  }
}

export function toAccountError(e: unknown): AccountError {
  return e instanceof AccountError ? e : new AccountError("server", e instanceof Error ? e.message : String(e));
}

// ───────────────────────── 请求 ─────────────────────────

async function call<T>(
  path: string,
  opts: { method?: string; body?: unknown; auth?: boolean } = {},
): Promise<T> {
  const base = baseUrl();
  if (!base) throw new AccountError("noServer", "no account server configured");
  const headers: Record<string, string> = { Accept: "application/json" };
  if (opts.body !== undefined) headers["Content-Type"] = "application/json";
  const tok = token();
  if (opts.auth !== false && tok) headers.Authorization = `Bearer ${tok}`;

  let res: Response;
  try {
    res = await fetch(base + path, {
      method: opts.method ?? "GET",
      headers,
      body: opts.body === undefined ? undefined : JSON.stringify(opts.body),
    });
  } catch (e) {
    // 服务器没开、IP 写错、明文 HTTP 被系统拦下（Android 9+ / iOS ATS）都到这儿
    throw new AccountError("network", e instanceof Error ? e.message : String(e));
  }

  if (res.status === 401) throw new AccountError("unauthorized", "unauthorized", 401);
  if (res.status === 404) throw new AccountError("notFound", "not found", 404);
  if (!res.ok) throw new AccountError("server", `HTTP ${res.status}`, res.status);
  if (res.status === 204) return undefined as T;
  const text = await res.text();
  return (text ? JSON.parse(text) : undefined) as T;
}

// ───────────────────────── 接口 ─────────────────────────

/** 服务器上的设备（account-api 的 /device/list；配对码不在里面） */
export interface AccountDevice {
  device_uuid: string;
  device_name: string;
  /** 6 位控制码 */
  control_code: string;
  online: boolean;
  /** 最后一次心跳（Unix 毫秒） */
  last_seen: number;
}

/** 登录：成功就把 token 和用户名记下来（之后 api 带 Bearer） */
export async function login(username: string, password: string): Promise<string> {
  const r = await call<{ token?: string }>("/auth/login", {
    method: "POST",
    auth: false,
    body: { username, password },
  });
  if (!r?.token) throw new AccountError("server", "login returned no token");
  write(TOKEN_KEY, r.token);
  write(USER_KEY, username);
  return r.token;
}

/** 退出登录：删掉本地的 token（服务器没有会话，不用通知） */
export function logout() {
  write(TOKEN_KEY, null);
  write(USER_KEY, null);
}

/** 同账号的设备列表 */
export function listDevices(): Promise<AccountDevice[]> {
  return call<AccountDevice[]>("/device/list");
}

/** 取某台设备的配对码（连接时按需取，平时不落到这台电脑上） */
export async function credential(uuid: string): Promise<string | null> {
  const r = await call<{ pairing_code?: string }>(`/device/credential?device_uuid=${encodeURIComponent(uuid)}`);
  return r?.pairing_code ?? null;
}

/** 把本机登记到账号（被控端在线时才有控制码和配对码） */
export async function registerSelf(d: {
  uuid: string;
  name: string;
  controlCode: string;
  pairingCode: string;
}): Promise<void> {
  await call<{ ok: boolean }>("/device/register", {
    method: "POST",
    body: {
      device_uuid: d.uuid,
      device_name: d.name,
      control_code: d.controlCode,
      pairing_code: d.pairingCode,
    },
  });
}

/** 心跳：告诉服务器本机还在线（90 秒不心跳就算离线，见 account-api 的 OFFLINE_MS） */
export async function heartbeat(uuid: string): Promise<void> {
  await call<{ ok: boolean }>("/device/heartbeat", { method: "POST", body: { device_uuid: uuid } });
}

/** 被控端身份（桌面版才有）：控制台用它把本机登记到账号 */
export interface HostIdentity {
  code: number | null;
  pairing: string | null;
  name: string;
  /** 被控端此刻真的在跑。false = 身份是从配置里读的（macOS 开着控制台时），别的设备会看到离线 */
  hosting: boolean;
}

/** 读本机被控端的控制码和配对码；网页版没有（返回 null） */
export async function hostIdentity(): Promise<HostIdentity | null> {
  if (!isTauri()) return null;
  return invoke<HostIdentity>("host_identity");
}
