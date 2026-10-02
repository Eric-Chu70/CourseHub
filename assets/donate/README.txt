打赏码放置目录
==============

「设置 → 关于与支持 → 打赏支持」目前只展示微信打赏码：

  wechat_qr.jpg    微信收款码（已放入：Original 的赞赏码，1382x1382）

对话框内长按该码会把原图保存到系统相册（Android 写入「图片/CourseHub」，
iOS / 桌面端写入系统图片目录），实现见 lib/screens/settings_screen.dart
的 _DonateQrCode。

素材要求：正方形或接近正方形、留白充足（保存的是原图，清晰度直接决定
别人能否扫出来）。换图直接覆盖本文件即可，无需改代码；文件名若变更，
需同步 _showDonationDialog 里的 assetPath。

支付宝打赏码已下线（不再展示、不再预留占位）。

打赏者名单位于 lib/screens/settings_screen.dart 的 _kDonationRecords 常量。

打赏者名单维护
==============
名单来自 CloudBase 静态托管的 donors.json（与 latest.json 同源）：

  文件：backup/cloudbase/static-hosting/donors.json
  地址：https://coursehub-d2gkbrgm7c877557a-1412312719.tcloudbaseapp.com/donors.json

收到打赏后手动编辑该文件并重新上传到静态托管，全员即时生效、无需发版：

  {
    "donors": [
      { "wechatId": "昵称（用户同意公开的署名）", "amount": 6.66 },
      { "wechatId": "另一位", "amount": 20.00 }
    ]
  }

  - 数组顺序 = 展示顺序，新的打赏写在前面
  - 金额单位元，展示为 ￥xx.xx
  - 只放用户同意公开的署名；不想公开的可以写「一位同学」等代称
  - 拉取失败 App 回落本地缓存，再没有则显示空态，不打扰用户
