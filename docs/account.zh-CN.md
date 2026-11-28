# 账号与账号设备（account-api）

[← 回 README](../README.md)

Airhand 原本是**控制码驱动**的：被控端连上中转服务器后拿到 6 位控制码，控制端输码找设备；"我的设备"只是本机
`config.toml` 里的一份本地记录，换台电脑就看不到。

这个版本加了一条**账号线**：登录一个账号之后，同账号下在线的设备会直接列出来，点一下就连，配对码由服务器按需下发。
它和原来的控制码方式并存——不影响的，控制码照样能手输。

```
被控端 A ──┐                        ┌── 控制端 B（登录后看到 A、C）
被控端 C ──┴── account-api（自建）──┘
                    │
            中转服务器（UDP 4433，不参与账号）
```

账号服务只存**设备元数据 + 加密后的配对码**，不参与 Airhand 的 QUIC 传输和端到端加密：会话仍然只在两台设备之间
加密，服务器连字节都看不到。

## 服务器

用 `account-api/`（Node + SQLite）自己部署，接口和部署方式见那里的 README。要点：

| 接口 | 用途 |
|---|---|
| `POST /auth/login` | 固定账号密码 → 永不过期的 token |
| `POST /device/register` | 被控端登记自己的控制码和配对码（upsert） |
| `POST /device/heartbeat` | 心跳，90 秒没有就算离线 |
| `GET /device/list` | 同账号的设备（不含配对码） |
| `GET /device/credential` | 按需取某台的配对码 |

## 客户端

### 登录页

没登录时整个窗口就是登录页（`client/src/components/LoginView.tsx`）：账号、密码、服务器地址。
登录成功后 token 存在 WebView 的 localStorage 里，下次打开直接进控制台；**token 不会过期**，只有"退出登录"（设置菜单里）才删。

服务器地址的来源，优先级从高到低：

1. 登录页里手填的（存 localStorage）——内网换了 IP 不用重新打包
2. 构建时注入的 `VITE_AIRHAND_ACCOUNT_API`（见 `.github/workflows/build-airhand.yml` 的 `AIRHAND_ACCOUNT_API` secret）
3. 都没有：登录页会把地址栏摊开，逼你填一个

地址格式必须是 `http(s)://host:port`，不带路径。

### 账号设备

新建连接页里，"我的设备"上面多了一块"账号设备"（`client/src/components/AccountDevices.tsx`）：
同账号的设备、控制码、在线状态、最后在线时间。点一下就直接连——配对码在这时候才从服务器取
（`GET /device/credential`），不存在本机。取不到（对方换过配对码、服务器上那份过期了）就退回原来的流程：
Airhand 要求配对码时界面会让你输。

离线的设备也能点：服务器会让连接等着，对方一上线就接上，和"我的设备"里的重连一样。

### 本机登记

控制台每 45 秒做两件事（`client/src/lib/actions.ts` 的 `startAccountSync`）：把本机登记到账号、拉一次设备列表。
登记需要本机的**控制码和配对码**，这两个原本只有托盘知道，所以 Rust 端加了一个命令 `host_identity`
（`src-tauri/src/lib.rs`）把它们交给控制台。

**限制**：控制码和配对码只在被控端连着服务器时才有。macOS / Linux 上打开控制台时被控端会停下，
所以这两台上"本机登记"要等切回被控端模式之后才会成功；Windows 上被控端一直跑着（系统服务或本进程），没有这个问题。
界面上会显示"这台电脑还没登记到账号"，旁边有"重新登记"。

### iOS（原生界面）

iOS 是原生 SwiftUI，不加载 `client/` 那套 React 界面，所以账号是另写的一套：

| 文件 | 作用 |
|---|---|
| `ios/Airhand/Core/Account.swift` | account-api 客户端（`URLSession`）+ `@Observable` 的 `Account`：登录、token、设备列表、取配对码、登记本机、45 秒同步 |
| `ios/Airhand/UI/AccountSection.swift` | 首页里"账号"那一块：没登录是登录卡片，登录后是账号设备列表（在"我的设备"上面） |
| `ios/Shared/SharedStore.swift` | `BuildDefaults.accountAPI` 读 Info.plist 里的 `AirhandAccountAPI` |
| `ios/Airhand/Core/AppModel.swift`、`App.swift` | 启动时若已登录就开始同步；回前台拉一次，退后台停掉 |

登录状态存在 App Group 里的 `account.json`（服务器地址、token、用户名、本机 uuid），和"我的设备"分开。

**本机登记**：控制码优先取正在共享时的实时值，没在共享就用上次存下的（`SavedHostCode`），
所以手机即使没在共享也能被别的设备看到，只是显示离线。配对码只在共享过之后才有
（广播扩展把 Rust 生成的配对码写进 `pairing.json`）——从没共享过的手机登记不上，
界面会提示"先到共享本机开始共享一次"。

地址来源和桌面端一样：先读 `account.json` 里手填过的，其次构建时写进 Info.plist 的 `AirhandAccountAPI`
（`scripts/build-ipa.sh` 从环境变量 `AIRHAND_ACCOUNT_API` 传进 xcodebuild）。

## 桌面端的 CSP（最容易漏的一条）

`client/src-tauri/tauri.conf.json` 里的 `connect-src` 原本只放行了自己、IPC 和 `ws://127.0.0.1:*`，
**没有任何 http 地址**。Tauri 的窗口加载了这份 CSP，所以请求在发出去之前就被 WebView 掐掉：

```
Refused to connect ... violates Content Security Policy directive "connect-src ..."
```

`fetch` 只会抛一个 `TypeError`，前端显示「连不上账号服务」，而服务端日志干干净净——
和第 3 条的样子一模一样，但原因完全不同。现在 `connect-src` 末尾加了 `http: https:`。

为什么是通配而不是写死地址：账号服务地址可以在登录页里手填（内网换 IP 不用重新打包），
构建期根本不知道最终会连哪个 host。代价是这个窗口可以请求任意 http/https 地址——
对一个自托管的远控工具来说可以接受，但别在里面加载第三方网页。

网页控制台（浏览器打开）不受这条影响，`index.html` 里没有 CSP meta。

## 明文 HTTP 的三个坑

账号服务一般跑在内网，`http://` 就够了，但系统会拦：

- **Android 9+**：`AndroidManifest.xml` 的 `<application>` 上要 `android:usesCleartextTraffic="true"`
  （Android 端还没接账号，加的时候一并加）
- **iOS**：`Info.plist` 要 ATS 例外。`ios/project.yml` 里已经设了 `NSAppTransportSecurity →
  NSAllowsArbitraryLoads = true`——例外域名（`NSExceptionDomains`）填不了 IP，而账号服务就是
  `http://192.168.x.x:8080`，所以只能整体放开。想收紧就改成只走 https，或者给账号服务挂个域名
- **CORS**：客户端是从 `tauri://localhost` 发请求的，`account-api` 里已经放开了 `Access-Control-Allow-Origin`
  （只用 Bearer token、不用 cookie，所以放开 `*` 是安全的）

症状都是"网络错误"，而且服务端日志里什么都没有——先怀疑这三条。

## 安全

- 密码只在登录那一次发给服务器，客户端不存
- token 是 HMAC-SHA256 自签的，没有过期时间：换服务器上的 `TOKEN_SECRET` 会让所有客户端立刻失效（要重新登录）
- 配对码在服务器上用 AES-256-GCM 加密存，列表接口永远不返回它；换 `DEVICE_SECRET` 会让已存的配对码全部解不开
  （所有设备要重新配对），两个密钥都别乱换，并且和 `account-data/` 一起备份

## 设备什么时候出现在列表里

列表里放的是"能连的机器"，不是"登录过的机器"——一台设备要能被连上，得先有控制码和配对码。

- **桌面端**：控制码和配对码都是固定的，存在 `config.toml`（`[code]`、`[host]` 的 `pairing`）。
  登录账号后每 45 秒拿它们登记一次。macOS / Linux 上打开控制台时被控端会暂停（见
  `client/src-tauri/src/status.rs` 的 `HOST_WITH_CONSOLE`），这时用的是配置里存下来的那一份，
  所以这台电脑照样出现在列表里、只是显示离线：关掉控制台、被控端起来就能连上（点它会等着，不报错）。
  没在共享时只登记一次——登记会刷新 `last_seen`，一直刷新别的设备就会以为它一直在线。
- **iOS**：手机要有控制码，得先在"共享本机"里开过一次投屏广播。从没共享过的手机没有身份可登记，
  界面上会写明原因。

以后改这块要注意：桌面端的登记循环跑在控制台的网页里，而 macOS / Linux 上控制台一关窗口就销毁了，
循环也跟着没了——所以不能指望"被控端跑起来之后再登记"，只能在控制台活着的时候把固定身份报上去。
