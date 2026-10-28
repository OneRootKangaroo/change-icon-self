# change-icon-self

在 vivo / iQOO（OriginOS）上，不换主题、不刷机，把桌面图标批量换成自己的图片。

## 这是什么

OriginOS 的桌面图标由第三方主题提供，主题里没有的应用只能用系统默认图标。本项目利用已有的 root 权限，把任意图片按主题规范生成图标，写入主题图标目录和桌面图标缓存，让桌面上任何应用显示你指定的图片。

全程不修改应用本身，不重装应用，不丢数据。

## 验证环境

- 机型：vivo（Qualcomm 平台），Android 14，内核 6.1（android14-6.1 GKI）
- 桌面：com.bbk.launcher2
- root：KernelSU（临时 root 方案），shell 已授权
- 主题：i主题中已应用任一第三方主题

其它机型 / OriginOS 版本未验证，但思路通用；路径、owner、SELinux 上下文等硬编码值可能需要按实测调整（见下文「适配其它设备」）。

## 用法

```bash
# 1. 把图片放进 icon/，文件名 = 桌面上显示的应用名（不区分大小写）
#    例如: 微信.png  ChatGPT.jpg  电话.jpeg
# 2. 手机连上 adb（需 root, KernelSU 已授权 shell）
./push_icons.sh
```

macOS 也可以直接双击 `应用自定义图标.command`。

脚本的流程：

1. root 读取桌面数据库 `launcher.db` 的 `location_*` 表，取出每行的「标题 + 组件名 + 行号」
2. 用标题匹配 `icon/` 里的同名图片
3. 按主题几何规范生成 4 个尺寸变体（240x240 / 240x480 / 480x240 / 480x480），自动裁透明边、等比缩放、圆角遮罩
4. 推送到 `/data/bbkcore/theme/icons/`（文件名 = 组件类名，另附一套包名命名），修复 owner / 权限 / SELinux 上下文
5. 把 240 档 PNG 按「表名 + 行号」精确写入桌面图标缓存
6. 重启桌面生效

## 实测结论（逆向依据，供参考）

- vivo 桌面图标缓存在 `/data/user_de/0/com.bbk.launcher2/databases/launcher.db` 的 `location_jan` / `location_jan_drawer` / `location_feb` / `location_feb_drawer` / `location_simple` 表的 `icon` 字段（240x240 PNG BLOB）。**桌面不监听主题目录变化，重启桌面不会重读图标**，必须直接写缓存
- 「应用主题」没有可复用的触发命令：`intent.action.theme.changed` 广播单独发无效，i主题 实际是写 Settings + 桌面自己全量重建缓存
- 主题图标文件按**组件类名**命名（如电话 = `com.android.dialer.TwelveKeyDialer.png`），应用信息/分身等入口按包名命名，两套都要推
- 图标几何（以主题自带图标缓存实测）：画布 240x240，四周透明边距 = 边长 x 21/240，圆角半径 = 可见边 x 39/198。边距给大了会让图标视觉上明显小于其它图标
- 桌面被 force-stop 后系统会立刻自动拉起，它按启动瞬间读到的缓存渲染——所以写库完成后要**再 force-stop 一次**再启动
- 同一包名多入口（如电话/联系人同属 com.android.contacts）靠组件名区分，按包名匹配会串图

## 注意

- **切换/重新应用主题会清空** `/data/bbkcore/theme/icons` 并重置桌面缓存，之后需要重跑本脚本
- 缓存写入前会自动备份数据库到 `/data/local/tmp/launcher.db.bak`，出问题可回滚
- 系统更新可能修复临时 root 依赖的内核漏洞，root 失效后本方案不可用（脚本会在第一步权限检查时直接报错退出，不会写坏数据）
- 桌面布局、应用名称以手机实际显示为准；`[跳过]` 列表会提示本地有图但桌面没有同名应用

## 适配其它设备

以下值是本机实测硬编码，换设备需要确认：

- 主题图标目录 `/data/bbkcore/theme/icons`，owner `u0_a345`，权限 777，SELinux `u:object_r:vivo_data_file:s0:c512,c768`
- 桌面数据库路径与 owner `u0_a108`（可用 `adb shell su -c 'ls -lZ'` 对照实测值修改脚本头部常量）

## 免责

仅供个人学习与备份用途。操作涉及系统数据目录，请自行承担风险，先备份再动手。
