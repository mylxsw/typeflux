# iOS 运行、安装与部署

在仓库根目录运行 `make ios-run`，即可完成 iOS 模拟器的构建、启动、安装和应用启动。只想查看界面、暂时没有账号时，运行 `make ios-preview`。完成一次性的设备配对和签名配置后，`make ios-deploy` 可以把应用构建、安装并启动到指定 iPhone。

这里的“部署”指安装 iOS 客户端到开发设备。应用默认连接 Typeflux 云端 API；这些命令不启动或部署后端，也不上传应用到 TestFlight / App Store。仓库原有的 `make run`、`make dev`、`make release` 仍用于 macOS。

iOS 客户端是独立的 SwiftUI 应用：账号和会话由云端服务提供，消息通过流式接口返回，手机负责展示和输入。它复用共享的 `TypefluxChat` 包，构建时不会编译 macOS 的语音模型或桌面工具。正常聊天需要联网；离线预览只用于界面演示，不提供离线模型推理。

## 1. 第一次运行

### 准备开发环境

- 使用能运行相应 Xcode 版本的 Mac，安装完整的 **Xcode 26 或更高版本**。只有 Command Line Tools 不够。源码使用较新的 Swift 编译器特性和 iOS 26 SDK API；应用的最低运行版本是 **iOS 17**，与构建工具版本不同。
- 启动一次 Xcode，按界面提示完成许可协议和必要组件安装。在 Xcode Settings 的 Components / Platforms 页面安装一个 iOS Simulator runtime；如没有模拟器，在 Window → Devices and Simulators 中创建 iPhone 模拟器。
- 确认终端能运行 Python 3.9+（`python3`）、`make`、`xcodebuild` 和 `xcrun`。模拟器构建不需要 Apple Developer 账号、签名证书或实体 iPhone。

检查当前工具链：

```sh
xcode-select -p
xcodebuild -version
python3 --version
```

如果 `xcode-select -p` 指向 `/Library/Developer/CommandLineTools`，可以在当前终端选择已安装的完整 Xcode，不必修改全局设置：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

若安装位置不同，请替换上述路径。首次启动的准备工作通常在 Xcode 界面完成；若 Xcode 明确提示许可或组件未初始化，也可以自行执行 `sudo xcodebuild -license` 阅读并接受协议，再执行 `sudo xcodebuild -runFirstLaunch`。Make 命令不会替你接受许可或运行提权操作。

### 下载并一键运行

```sh
git clone https://github.com/mylxsw/typeflux.git
cd typeflux
make ios-doctor
make ios-run
```

已有仓库时，直接在仓库根目录执行后两条命令即可。首次编译需要一些时间，后续构建复用缓存。成功后，Simulator 会打开并显示 Typeflux；未登录时进入登录界面。使用已有的 Typeflux 账号登录后可以查看云端会话并聊天，真实请求使用账号的额度。

`ios-run` 自动选取可用的 iPhone 模拟器：优先使用已启动的 iPhone，否则选择最新 runtime 下的 iPhone。也可以明确指定设备：

```sh
make ios-devices
TYPEFLUX_IOS_SIMULATOR='<simulator-UDID>' make ios-run
```

把 `<simulator-UDID>` 替换为设备列表里的实际标识符；不要填设备名称或 `booted`。脚本会打印选中的目标。构建保留模拟器的本地签名和 Keychain entitlement，不需要关闭代码签名。

## 2. 不登录的离线界面预览

```sh
make ios-preview
```

该命令使用 Debug 构建，通过 `--synthetic-preview --synthetic-rich` 启动应用。预览使用内存中的测试账号和包含 Markdown、推理等内容的模拟会话，不发送生产请求，也不消耗真实账号额度。适合快速查看聊天、模型选择、设置等界面；预览效果不代表真实登录、模型服务或设备权限已经验证。若当前终端设置了 `TYPEFLUX_IOS_CONFIGURATION=Release`，请改成 `Debug`，预览命令会拒绝 Release 配置。

恢复正常联网模式：

```sh
make ios-run
```

每次运行命令都会重新启动应用，因此旧的预览启动参数不会继续生效。Release 构建不包含该预览入口。更多场景参数及截图参见 [iOS 开发说明](IOS_CHAT.md#build-and-test)。

## 3. 只构建，或只安装不启动

```sh
make ios-build
make ios-install
```

- `ios-build` 编译模拟器应用，不安装、不启动应用。
- `ios-install` 编译应用，启动目标模拟器并安装，随后可以从模拟器主屏幕点击 Typeflux。
- `ios-run` 在安装之后直接启动正常应用。

这三个命令默认使用 Debug。需要验证模拟器 Release 构建时：

```sh
TYPEFLUX_IOS_CONFIGURATION=Release make ios-run
```

## 4. 一键安装到实体 iPhone

### 一次性准备

1. 用数据线连接并解锁 iPhone，在手机上选择“信任此电脑”。在 Xcode 的 Devices and Simulators 中确认设备已配对、可用，并完成所需设备支持组件的准备。
2. 在手机 Settings → Privacy & Security → Developer Mode 中开启开发者模式，按提示重启并确认。该模式用于开发安装；操作细节见 [Apple 的 Developer Mode 说明](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)。
3. 在 Xcode Settings → Apple Accounts 中登录开发者账号。打开工程，选择 `TypefluxIOS` target 的 Signing & Capabilities，确认使用可管理 `app.typeflux.ios` 的团队、自动签名和开发签名证书。
4. 本项目包含 Sign in with Apple capability。使用具备该能力的 Apple Developer Program 团队，并确认 `app.typeflux.ios` 的 App ID 已启用它；不要把免费 Personal Team 当成该签名配置的替代。可用能力取决于成员资格，详见 [Apple 的 iOS 能力表](https://developer.apple.com/help/account/reference/supported-capabilities-ios) 和 [Sign in with Apple 配置](https://developer.apple.com/help/account/capabilities/about-sign-in-with-apple)。

打开工程的命令：

```sh
open Apps/iOS/TypefluxIOS.xcodeproj
```

脚本会优先使用明确设置的 `TYPEFLUX_IOS_TEAM`，然后读取 Xcode 工程对应构建配置的团队；工程未配置时，从本机可用的 Apple 开发证书中识别团队。只有一个团队时自动使用，多个时在终端列出供选择；无交互终端时需明确设置 `TYPEFLUX_IOS_TEAM`。

团队 ID 是 Apple Developer 账号中的 **Team ID**，不是账号邮箱、证书名称或 App ID。团队、证书和描述文件保存在自己的开发环境中，不要提交到仓库。macOS 的 `scripts/setup_dev_cert.sh` 所创建的本地证书不能用于 iPhone 签名。

### 部署命令

```sh
make ios-devices
TYPEFLUX_IOS_DEVICE='<physical-device-UDID>' \
make ios-deploy
```

复制 `xctrace` 列表中实体设备的 UDID，而非 Simulator UDID 或 `devicectl` 的 CoreDevice UUID。部署会构建签名的 iPhone 应用，安装到明确指定的设备并启动。手机保持解锁；如果首次出现信任开发者或调试授权提示，按系统提示完成。以后重复同一命令即可更新应用。

部署和归档会向 Xcode 传入 `-allowProvisioningUpdates`，允许它使用已登录的开发者账号更新必要的签名描述文件等资源。真机部署还会传入 `-allowProvisioningDeviceRegistration`，在必要时将明确指定的设备注册到该开发团队；模拟器和归档不会执行设备注册。正常使用只需首次配置；脚本无法代替设备上的信任、Developer Mode 开关、Apple 账号登录或团队权限配置。部署中的签名错误应在 Xcode Signing & Capabilities 中解决，不要通过关闭签名绕过。

真实 Apple 登录还要求后端接受 iOS token：API 的逗号分隔 `APPLE_OIDC_CLIENT_ID` 配置中应包含 `app.typeflux.ios`。客户端安装成功不等于后端已完成这项配置。相机、麦克风和语音识别请在实体设备上授权并验证。

## 5. 生成 Release archive

完成上述团队和签名配置后：

```sh
TYPEFLUX_IOS_TEAM='<TEAMID>' make ios-archive
```

该命令固定使用 Release，生成本地 `.xcarchive`，不需要连接 iPhone。默认输出为：

```text
.xcode-ios-derived/archives/TypefluxIOS.xcarchive
```

为避免覆盖之前的产物，目标路径已经存在时命令会停止。再次归档时指定新路径：

```sh
TYPEFLUX_IOS_TEAM='<TEAMID>' \
TYPEFLUX_IOS_ARCHIVE_PATH='.xcode-ios-derived/archives/TypefluxIOS-next.xcarchive' \
make ios-archive
```

在 Xcode Organizer 中检查归档：

```sh
open .xcode-ios-derived/archives/TypefluxIOS.xcarchive
```

归档不是可直接安装的 `.ipa`，也不会自动发布。TestFlight 或 App Store 分发需要另行配置 App Store Connect 应用、分发签名和相应资料，在 Organizer 中验证并选择分发方式，参见 [Apple 分发说明](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)。当前 iOS 仍有账号删除等未完成能力，完整限制见 [iOS 开发说明](IOS_CHAT.md#current-behavior)；成功归档不表示应用已具备上架条件。

## 6. 使用测试环境或本地后端

默认 API 是 `https://api.typeflux.app`。要切换到自己可访问的 HTTPS 测试环境，在构建时传入地址：

```sh
TYPEFLUX_API_URL='https://api-staging.example.com' make ios-run

TYPEFLUX_API_URL='https://api-staging.example.com' \
TYPEFLUX_IOS_DEVICE='<physical-device-UDID>' \
TYPEFLUX_IOS_TEAM='<TEAMID>' \
make ios-deploy
```

以上域名是示例，请替换为真实环境。配置会写入本次构建的应用，修改后需要重新构建、安装；仅在 Mac 终端导出变量不会改变已经安装的应用。登录凭据按 API 地址隔离，切换环境后需要使用对应环境的账号。

应用默认只接受 HTTPS 地址，不接受含用户名、密码、查询参数或 fragment 的 URL。不要把密钥或账号密码放进 URL、Makefile 或工程文件。

使用 MacBook 或 Mac mini 的局域网 API，可以直接执行：

```sh
make dev-macbook PLATFORM=ios
make dev-macmini PLATFORM=ios
make dev-macbook PLATFORM=ios DEVICE=<真机或模拟器的UDID>
```

前两条命令会列出已配对的 iPhone/iPad 和可用的 iOS 17+ 模拟器，显示名称、类型、状态及 UDID。
输入编号后继续构建、安装和启动；输错编号会重新提示，`q` 或 Ctrl+C 取消。
只有一个目标时自动使用它。指定 `DEVICE` 时跳过交互；在没有交互终端且存在多个目标时，必须明确指定。
真机自动识别开发者团队，多个团队时继续选择；也可以用 `TYPEFLUX_IOS_TEAM` 指定。
选择模拟器则无需开发者团队。

MacBook 对应 `http://mac-pro.local:8080`，Mac mini 对应 `http://mac-mini.local:8080`。
这些命令自动开启 Debug 局域网 HTTP 配置；Release 和归档仍要求 HTTPS。
不加 `PLATFORM=ios` 时，它们仍启动 macOS 应用。
其他局域网 API 可以明确开启 Debug HTTP：

```sh
TYPEFLUX_API_URL=http://192.168.1.20:8080 TYPEFLUX_ALLOW_INSECURE_HTTP=YES make ios-run
```

先独立启动 `typeflux-api`，确保设备能解析主机名并访问 8080 端口，首次连接时允许 iOS 的局域网访问权限。
实体 iPhone 上的 `localhost` / `127.0.0.1` 指向手机自身，不能用来连接 Mac。
HTTP 仅限 `.local`、localhost 和回环/私有/链路本地 IP，公网 API 使用 HTTPS。
后端配置和部署属于 `typeflux-api` 仓库的工作流。

## 7. 命令和配置速查

| 命令 | 用途 |
| --- | --- |
| `make ios-help` | 查看 iOS 命令帮助 |
| `make ios-doctor` | 检查本机 Xcode 工具链与模拟器环境 |
| `make ios-devices` | 列出模拟器和实体设备，获取目标标识符 |
| `make ios-build` | 仅构建模拟器应用 |
| `make ios-install` | 构建、启动模拟器并安装应用 |
| `make ios-run` | 构建、安装并启动正常应用 |
| `make ios-preview` | Debug 构建、安装并启动离线预览 |
| `make ios-deploy` | 构建、安装并启动指定实体 iPhone 上的应用 |
| `make ios-archive` | 创建本地 Release archive |
| `make ios-test` | 运行原有的 iOS 单元和 UI 测试流程 |
| `make ios-test-scripts` | 运行安装、启动和部署脚本的自动化测试 |

所有命令从仓库根目录执行。构建、设备检查、安装和部署命令共用 `scripts/ios.py` 的编排逻辑；`ios-test` 复用已有的 `scripts/test_ios.sh`，`ios-test-scripts` 运行 Python `unittest`。

| 环境变量 | 默认值 / 用途 |
| --- | --- |
| `DEVELOPER_DIR` | 可选，指定完整 Xcode 的 `Contents/Developer` 目录 |
| `TYPEFLUX_IOS_SIMULATOR` | 可选，模拟器 UDID；不设置时自动选取 iPhone |
| `TYPEFLUX_IOS_DEVICE` | `ios-deploy` 必填，实体设备 UDID |
| `TYPEFLUX_IOS_TEAM` | 可选，明确指定开发团队 ID；默认从 Xcode 工程或本机开发证书识别 |
| `TYPEFLUX_IOS_CONFIGURATION` | `Debug`；可设 `Release`。预览仅接受 Debug，归档固定 Release |
| `TYPEFLUX_IOS_DERIVED_DATA` | `.xcode-ios-derived`；应用构建缓存和产物目录 |
| `TYPEFLUX_IOS_ARCHIVE_PATH` | 默认在配置的 DerivedData 下的 `archives/TypefluxIOS.xcarchive`；归档路径，不能已存在 |
| `TYPEFLUX_API_URL` | `https://api.typeflux.app`；本次构建的 API 地址，Debug 可明确开启局域网 HTTP |
| `TYPEFLUX_ALLOW_INSECURE_HTTP` | 设置为 `YES` 时，Debug 构建允许局域网 HTTP；新环境命令自动传入 |
| `TYPEFLUX_IOS_TARGET` | `PLATFORM=ios` 启动时的真机或模拟器 UDID，Make 通过 `DEVICE` 传入 |
| `TYPEFLUX_IOS_TEST_DESTINATION` | 仅测试脚本使用；格式为 `platform=iOS Simulator,id=<UDID>` |
| `TYPEFLUX_IOS_TEST_RESULT_BUNDLE_PATH` | 仅测试脚本使用；新的 `.xcresult` 路径，用于保留测试报告、覆盖率及截图 |

自定义 DerivedData 和 archive 的相对路径以仓库根目录为基准，也可以使用绝对路径。未单独设置 archive 路径时，它会随 DerivedData 目录一起移动。

构建产物位于 DerivedData 下的 `Build/Products/Debug-iphonesimulator/TypefluxIOS.app`，Release 或真机对应 `Release-iphonesimulator`、`Debug-iphoneos` 等目录。构建日志输出到当前终端；脚本遇到编译、安装或启动失败会返回非零退出码。

运行测试并保留结果：

```sh
make ios-test-scripts
swift test --package-path Packages/TypefluxChat
TYPEFLUX_IOS_TEST_DESTINATION='platform=iOS Simulator,id=<UDID>' \
TYPEFLUX_IOS_TEST_RESULT_BUNDLE_PATH='.xcode-ios-derived/ios-tests.xcresult' \
make ios-test
```

测试目标通过 `TYPEFLUX_IOS_TEST_DESTINATION` 独立选择，不能用 `TYPEFLUX_IOS_SIMULATOR` 代替。测试脚本固定使用 `.xcode-ios-derived`，不读取 `TYPEFLUX_IOS_DERIVED_DATA`。结果路径不能已存在。UI 测试会在模拟器照片库中加入一张测试图片，不删除已有照片；使用离线数据，不验证生产账号登录或真实模型响应。

## 8. 停止应用与常见问题

启动命令在应用启动成功后返回，Simulator 和应用继续运行。可以直接关闭 Simulator，或明确停止某台模拟器上的应用：

```sh
xcrun simctl terminate '<simulator-UDID>' app.typeflux.ios
xcrun simctl shutdown '<simulator-UDID>'
```

第二条会关闭该模拟器内的所有应用。安装、重跑不会主动抹掉整个模拟器；开发期间应用升级通常保留已有容器数据。需要退出真实账号时，使用应用设置中的退出登录。

| 现象 | 处理方法 |
| --- | --- |
| 提示不是完整 Xcode，或缺少 iPhone SDK | 检查 `xcode-select -p`，设置正确的 `DEVELOPER_DIR`，完成 Xcode 初始化；升级到 Xcode 26+ |
| 没有可用的 iPhone 模拟器 | 在 Xcode Settings 安装 iOS runtime，再创建 iPhone 模拟器；执行 `make ios-devices` 确认 |
| 指定 UDID 不存在或不可用 | 重新查看 `make ios-devices`，使用当前 runtime 下可用设备的标识符 |
| 已安装但仍显示离线测试数据 | 执行 `make ios-run`；不要在 Xcode scheme 中保留 `--synthetic-preview` 参数 |
| 无法识别团队，或提示需要 provisioning profile | 在 Xcode 登录开发者账号并确认开发证书、团队和 App ID entitlement；必要时设置 `TYPEFLUX_IOS_TEAM` |
| 找不到实体设备或启动失败 | 解锁手机、确认信任和 Developer Mode，等待 Xcode 配对完成，再核对实体设备标识符 |
| Apple 登录失败 | 检查 App ID 的 Sign in with Apple、签名 profile，以及后端 `APPLE_OIDC_CLIENT_ID` 是否包含 iOS bundle ID |
| 网络错误或切换环境后没有历史 | 检查构建使用的 HTTPS 地址、设备网络和证书；不同 API 的登录与云端历史相互独立 |
| 相机、听写不可用 | 优先在真机验证，在系统设置授予相机、麦克风和语音识别权限；模拟器不覆盖完整硬件能力 |
| archive / `.xcresult` 已存在 | 选择新的输出路径；确认旧产物不再需要后再自行删除 |
| 反复构建出现缓存相关错误 | 先保留错误输出，用新的 `TYPEFLUX_IOS_DERIVED_DATA` 目录重建，以便与原有缓存隔离排查 |

进一步查看 [iOS 架构与测试说明](IOS_CHAT.md)、[Make 命令](MAKE_COMMANDS.md) 和 [v4 界面验证记录](validation/gul-199-ios-v4.md)。
