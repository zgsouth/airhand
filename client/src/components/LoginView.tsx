// 登录页：账号服务（account-api）的用户名 / 密码。没登录时整个窗口就是这一页（见 App）。
//
// 服务器地址默认用构建时注入的 VITE_AIRHAND_ACCOUNT_API（见 .github/workflows/build-airhand.yml）；
// 内网换了 IP、或者构建时没注入，就在这一页改——存在 localStorage，下次不用再填。
// 登录成功后 token 也存在 localStorage，下次打开直接进控制台（token 不会过期，退出登录才删）。
import { useEffect, useRef, useState } from "react";
import { BUILTIN_BASE, baseUrl } from "../lib/account";
import { signIn } from "../lib/actions";
import { api } from "../lib/api";
import { setLang, useT } from "../lib/i18n";
import { NATIVE_WINDOW_BUTTONS } from "../lib/platform";
import { store, useStore } from "../lib/store";
import { IconArrowRight, IconWarn } from "./Icons";
import { Logo } from "./Logo";
import { WindowButtons } from "./TitleBar";

const LAST_USER_KEY = "airhand.account.lastUser";

/** 上次登录用的用户名（只记名字，密码从来不存） */
function lastUser(): string {
  try {
    return globalThis.localStorage?.getItem(LAST_USER_KEY) ?? "";
  } catch {
    return "";
  }
}

function rememberUser(user: string) {
  try {
    globalThis.localStorage?.setItem(LAST_USER_KEY, user);
  } catch {
    // 存不了就算了
  }
}

/** 地址的格式要求（和 workflow 里的校验一致）：http(s)://host:port，不带路径 */
const looksLikeBase = (s: string) => /^https?:\/\/[^/]+$/.test(s.trim());

export function LoginView() {
  const t = useT();
  const acc = useStore((s) => s.account);
  const app = useStore((s) => s.app);
  const [user, setUser] = useState(lastUser);
  const [pass, setPass] = useState("");
  const [base, setBase] = useState(() => baseUrl() || BUILTIN_BASE);
  // 没有可用的地址（构建时没注入）时直接把地址栏摊开
  const [showBase, setShowBase] = useState(() => !baseUrl());
  const passRef = useRef<HTMLInputElement | null>(null);

  // 登录页也把版本号和语言取回来（平时是控制台取的，这一页把控制台换掉了）
  useEffect(() => {
    if (store.get().app) return;
    void api.appInfo().then((info) => {
      store.setApp(info);
      setLang(info.lang);
    });
  }, []);

  const baseOk = looksLikeBase(base);
  const ready = user.trim().length > 0 && pass.length > 0 && baseOk;
  const busy = acc.busy;
  const error = acc.error;

  /** 账号服务的错按当前语言显示；`detail` 是技术信息，跟在后面 */
  const errorText = (() => {
    if (!error) return null;
    switch (error.kind) {
      case "noServer":
        return t("account.errNoServer");
      case "network":
        return t("account.errNetwork", { detail: error.detail });
      case "unauthorized":
        return t("account.errAuth");
      default:
        return t("account.errServer", { detail: error.detail });
    }
  })();

  const submit = async (e?: React.FormEvent) => {
    e?.preventDefault();
    if (!ready || busy) return;
    try {
      await signIn(user.trim(), pass, base);
      rememberUser(user.trim());
    } catch {
      // 错误记在 store 里（界面上面的红色提示），这里只管把焦点放回密码框
      passRef.current?.focus();
      passRef.current?.select();
    }
  };

  return (
    <div className="app">
      {/* 登录时没有标签栏，但窗口还是无边框的：留一条能拖动的空标题栏，别让窗口拖不动、关不掉 */}
      <header className={`titlebar ${NATIVE_WINDOW_BUTTONS ? "native-buttons" : ""}`} data-tauri-drag-region="deep">
        {!NATIVE_WINDOW_BUTTONS && (
          <div className="brand" aria-hidden>
            <Logo size={18} />
          </div>
        )}
        <div className="login-drag" data-tauri-drag-region />
        {api.frame && !NATIVE_WINDOW_BUTTONS && <WindowButtons />}
      </header>
      <main className="main">
        <div className="login">
          <div className="login-glow" aria-hidden />
          <form className="login-card" onSubmit={submit}>
            <div className="login-head">
              <Logo size={44} />
              <div>
                <h1>{t("account.login.title")}</h1>
                <p className="muted small">{t("account.login.subtitle")}</p>
              </div>
            </div>

            <label className="login-field">
              <span className="login-label">{t("account.login.user")}</span>
              <input
                className="login-input"
                value={user}
                autoFocus={!lastUser()}
                autoComplete="username"
                spellCheck={false}
                autoCapitalize="none"
                disabled={busy}
                onChange={(e) => setUser(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter") {
                    e.preventDefault();
                    if (user.trim()) passRef.current?.focus();
                  }
                }}
              />
            </label>

            <label className="login-field">
              <span className="login-label">{t("account.login.password")}</span>
              <input
                ref={passRef}
                className="login-input"
                type="password"
                value={pass}
                autoFocus={!!lastUser()}
                autoComplete="current-password"
                disabled={busy}
                onChange={(e) => setPass(e.target.value)}
              />
            </label>

            {errorText && (
              <div className="error-box" role="alert">
                <IconWarn size={15} />
                <span>{errorText}</span>
              </div>
            )}

            <button className="primary-btn" type="submit" disabled={!ready || busy}>
              {busy ? <span className="spinner" /> : <IconArrowRight size={18} />}
              <span>{busy ? t("account.login.busy") : t("account.login.submit")}</span>
            </button>

            {/* 服务器地址：平时收起来，只显示现在用的是哪个 */}
            <div className="login-server">
              {showBase ? (
                <>
                  <span className="login-label">{t("account.login.server")}</span>
                  <input
                    className={`login-input small ${base && !baseOk ? "invalid" : ""}`}
                    value={base}
                    placeholder="http://192.168.110.176:8080"
                    spellCheck={false}
                    autoCapitalize="none"
                    disabled={busy}
                    onChange={(e) => setBase(e.target.value)}
                  />
                  <span className="muted small">{t("account.login.serverHint")}</span>
                </>
              ) : (
                <button
                  type="button"
                  className="text-btn login-server-toggle"
                  title={t("account.login.server")}
                  onClick={() => setShowBase(true)}
                >
                  {t("account.login.server")}: <code>{base || "—"}</code>
                </button>
              )}
            </div>

            <div className="login-foot muted small">
              {t("account.login.foot", { version: app?.version ?? "—" })}
            </div>
          </form>
        </div>
      </main>
    </div>
  );
}
