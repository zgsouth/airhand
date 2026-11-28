// 账号设备：登录的账号在同一条服务器上登记过的设备（见 lib/account.ts、account-api）。
//
// 和下面的"我的设备"区别：我的设备是本机记下来的（config.toml），换台电脑就看不到；
// 账号设备存在服务器上，同一账号的每台电脑都看得到，配对码也在服务器上，点一下就能连，
// 不用再手输配对码。
import { type AccountDevice } from "../lib/account";
import { connectAccountDevice, refreshAccountDevices, registerThisDevice, signOut } from "../lib/actions";
import { api } from "../lib/api";
import { fmtCode, relativeTime } from "../lib/devices";
import { getLang, useT } from "../lib/i18n";
import { useStore } from "../lib/store";
import { IconLogout, IconMonitor, IconRefresh, IconUser, IconWarn } from "./Icons";

export function AccountDevices({ disabled }: { disabled: boolean }) {
  const t = useT();
  const acc = useStore((s) => s.account);
  const app = useStore((s) => s.app);

  if (!acc.user) return null;

  const busy = acc.busy;
  const devices = acc.devices;
  const error = acc.error;
  /**
   * 本机还没登记上的原因（被控端没连上服务器之类）。
   * 网页版没有被控端，谈不上"登记本机"，不显示这一条。
   * `notHosting` 不是失败：本机登记上了，只是此刻没在共享（macOS 开着控制台时被控端是停着的）。
   */
  const selfIssue = api.kind !== "web" && typeof acc.self === "string" ? acc.self : null;
  const selfNotHosting = selfIssue === "notHosting";
  const selfPending = selfIssue !== null && !selfNotHosting;

  return (
    <section className="nt-devices account-devices">
      <div className="section-title">
        <span>
          <IconUser size={14} />
          {t("accountDevices.title")}
          <span className="count">{devices.length}</span>
        </span>
        <span className="acct-actions">
          <span className="acct-user" title={acc.base}>
            {acc.user}
          </span>
          <button
            className="icon-btn subtle"
            title={t("accountDevices.refresh")}
            aria-label={t("accountDevices.refresh")}
            disabled={busy}
            onClick={() => void refreshAccountDevices()}
          >
            <IconRefresh size={13} className={busy ? "spin" : undefined} />
          </button>
          <button
            className="icon-btn subtle"
            title={t("account.logout")}
            aria-label={t("account.logout")}
            onClick={() => signOut()}
          >
            <IconLogout size={13} />
          </button>
        </span>
      </div>

      {/* 本机还没登记上：说清楚为什么（别的电脑这时看不到这台） */}
      {selfPending && (
        <div className="acct-note muted small" role="status">
          <span>{t("accountDevices.selfPending")}</span>
          <button className="text-btn" onClick={() => void registerThisDevice()}>
            {t("accountDevices.retry")}
          </button>
        </div>
      )}

      {/* 登记上了、但此刻没在共享：别的设备能看到这台，点了要等它上线 */}
      {selfNotHosting && (
        <div className="acct-note muted small" role="status">
          <span>{t("accountDevices.selfNotHosting")}</span>
        </div>
      )}

      {error && (
        <div className="error-box soft" role="status">
          <IconWarn size={14} />
          <span>
            {error.kind === "network"
              ? t("account.errNetwork", { detail: error.detail })
              : t("account.errServer", { detail: error.detail })}
          </span>
        </div>
      )}

      {devices.length === 0 ? (
        <p className="nt-empty muted small">{t(acc.loaded ? "accountDevices.empty" : "accountDevices.loading")}</p>
      ) : (
        <div className="device-list">
          {devices.map((d) => (
            <AccountDeviceItem key={d.device_uuid} d={d} disabled={disabled || busy} own={d.device_name === app?.hostname} />
          ))}
        </div>
      )}
    </section>
  );
}

function AccountDeviceItem({ d, disabled, own }: { d: AccountDevice; disabled: boolean; own: boolean }) {
  const t = useT();
  const title = d.device_name?.trim() || fmtCode(d.control_code);
  const seen = relativeTime(d.last_seen, Date.now(), getLang() === "zh" ? "zh-CN" : "en");
  return (
    <div
      role="button"
      tabIndex={0}
      // 离线的也能点：服务器会让连接等着，对方一上线就接上（和"我的设备"里的重连一样）
      className={`device-item ${disabled ? "disabled" : ""}`}
      title={[title, fmtCode(d.control_code), d.online ? t("accountDevices.online") : seen].filter(Boolean).join(" · ")}
      onClick={() => !disabled && void connectAccountDevice(d)}
      onKeyDown={(e) => e.key === "Enter" && !disabled && void connectAccountDevice(d)}
    >
      <span className={`avatar ${d.online ? "online" : ""}`}>{title.slice(0, 1).toUpperCase()}</span>
      <span className="device-meta">
        <span className="device-name">
          {title}
          {own && <span className="acct-self">{t("accountDevices.thisDevice")}</span>}
        </span>
        <span className="device-sub">
          <span className={`dot ${d.online ? "live" : "closed"}`} />
          {fmtCode(d.control_code)}
          {d.online ? ` · ${t("accountDevices.online")}` : seen ? ` · ${seen}` : ""}
        </span>
      </span>
      <span className="device-actions">
        <IconMonitor size={14} />
      </span>
    </div>
  );
}
