# 虚拟显示器驱动（MttVDD）

随 Windows 安装包带着的虚拟显示器驱动：被控端的显示器关了电源也能远程控制、防窥模式都靠它
（见 `src/host/virtual_display/`）。安装包把这几个文件放进安装目录的 `vdd\`，为所有用户安装时问用户要不要装，
装的时候运行 `airhand.exe --install-vdd`（见 `windows/hooks.nsh`）。

| 文件 | 说明 |
|---|---|
| `MttVDD.inf`、`mttvdd.cat`、`MttVDD.dll` | 驱动本身，原样取自发布包，**一个字节也不能改**（`mttvdd.cat` 是签过名的目录文件，里面有另外两个文件的哈希；`.gitattributes` 让 Git 不改换行符） |
| `LICENSE.txt` | 驱动的许可证（MIT） |

- 项目：Virtual Display Driver（MttVDD），<https://github.com/VirtualDrivers/Virtual-Display-Driver>，MIT 许可
- 版本：25.7.23 发布里的 `VirtualDisplayDriver-x86.Driver.Only.zip`（x64 驱动，INF 里的 `DriverVer` 是 12/24/2024,11.30.4.434）
- 发布包的 SHA-256：`e24210692b442b39af763536330ce78b423f19342b7a7792c26de3944e418b3a`
- 签名：SignPath Foundation 的代码签名证书（GlobalSign 签发，有效期到 2027-09-08）。不是微软的签名：安装时 Windows 会问
  要不要安装这个发布者的设备软件；Windows 11 ARM64 只认微软签名的驱动，装不上（所以只带了 x64 的）

| 文件 | SHA-256 |
|---|---|
| `MttVDD.inf` | `550d211fe481e74dfe3f9d724ed78be48b3a9113405965d683d9373e8d672f5d` |
| `mttvdd.cat` | `08a0093fc9b2e32b287a6f8a77ca4de0a31830d29fc33d2b13a918dc859468f6` |
| `MttVDD.dll` | `c9ca837f57a98fbd43bc416a7f535a95843626e7759eaf85cf0cd7ce334dbb05` |

## 更新

在 PowerShell 里（换成新版本的地址和哈希），核对发布包的 SHA-256 和签名之后再替换：

```powershell
$zip = "$env:TEMP\vdd.zip"
Invoke-WebRequest https://github.com/VirtualDrivers/Virtual-Display-Driver/releases/download/25.7.23/VirtualDisplayDriver-x86.Driver.Only.zip -OutFile $zip
(Get-FileHash $zip).Hash   # 和 GitHub 发布页上的 digest 对一下
Expand-Archive $zip "$env:TEMP\vdd" -Force
Get-AuthenticodeSignature "$env:TEMP\vdd\VirtualDisplayDriver\mttvdd.cat" | Format-List Status, SignerCertificate
Copy-Item "$env:TEMP\vdd\VirtualDisplayDriver\MttVDD.inf", "$env:TEMP\vdd\VirtualDisplayDriver\mttvdd.cat", "$env:TEMP\vdd\VirtualDisplayDriver\MttVDD.dll" .
```

新版本的设置文件格式（`vdd_settings.xml`，Airhand 每次启用前自己写，见 `src/host/virtual_display/device.rs`）、
硬件 ID（`Root\MttVDD`）、注册表里设置文件的位置（`HKLM\SOFTWARE\MikeTheTech\VirtualDisplayDriver` 的 `VDDPATH`）
变了的话要跟着改。
