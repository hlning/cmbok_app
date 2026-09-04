<div align="center">

<img src="https://cmbok.oss-cn-beijing.aliyuncs.com/readme/logo.png" width="96" alt="Cmbok">

# Cmbok

**你的下一款阅读软件，可以是 Cmbok**

漫画和图书双库合一：两套分开做的阅读器，共用一套书架、阅读进度和阅读历程。

![Platform](https://img.shields.io/badge/Platform-Android%20%7C%20iOS%20%7C%20Windows-3DDC84)
![License](https://img.shields.io/badge/License-MIT-yellow)
![Flutter](https://img.shields.io/badge/Flutter-3.10%2B-02569B?logo=flutter&logoColor=white)

不用注册账号 · 无广告无内购 · 不收集使用数据 · MIT 开源

<img src="https://cmbok.oss-cn-beijing.aliyuncs.com/readme/hero.webp" width="800" alt="Cmbok 桌面版与手机版">

</div>

---

## 两套阅读器，一个书架

漫画竖着翻、图书按字排版，两边的阅读器是分开做的，不是一套凑合两用。但书架、收藏、阅读进度、浏览记录和阅读历程是同一套，找书不用分两处。

<img src="https://cmbok.oss-cn-beijing.aliyuncs.com/readme/shelf.webp" width="720" alt="书架：漫画与图书混排">

## 阅读

翻页方式、字怎么排、纸什么颜色、屏幕点哪里翻页，都拆开到单项可调，调好还能存成预设。

- **翻页 10 种**：图书五种（含 GPU 着色器的仿真翻页、上下连续滚动），漫画五种（从右往左、消散、拼页跨话连读等），横屏支持双页
- **排版逐项可调**：字号字重行距段距字间距首行缩进各自独立，正文四边与页眉页脚边距分开算，整套设置存成预设
- **纸与字**：四种底色、14 张内置背景图、自定义图片；字体指一个文件夹整批导入
- **细节**：点击区域九宫格自定义、底栏按钮长按拖拽调序、音量键翻页、任何设置都能「只对这本书生效」

<img src="https://cmbok.oss-cn-beijing.aliyuncs.com/readme/read-1.jpg" width="200" alt=""> <img src="https://cmbok.oss-cn-beijing.aliyuncs.com/readme/read-2.jpg" width="200" alt=""> <img src="https://cmbok.oss-cn-beijing.aliyuncs.com/readme/read-3.jpg" width="200" alt="">

## 格式

EPUB / MOBI / AZW3 / TXT / PDF / CBZ / ZIP 七种格式，导进来就能读。TXT 自动认 UTF-8 和 GBK；EPUB 大文件按需解压，几百兆也是秒开；解析全在本地做，文件不上传到任何地方。

<img src="https://cmbok.oss-cn-beijing.aliyuncs.com/readme/local-shelf.webp" width="720" alt="本地书架">

## 听书

六类朗读引擎，断网也能读给你听。打底的是系统朗读：离线、不花流量、不用填密钥；想要更好的声音，可以接微软 Azure、OpenAI 兼容接口、小米 MiMo，或导入网络朗读引擎配置。

- 跟读高亮、自动翻页、睡眠定时（到点是暂停不是停止）
- 沉浸式播放页与迷你浮动条随时切，息屏和退出阅读器都不断
- 引擎、语速、音色都能只对当前这本书生效

<img src="https://cmbok.oss-cn-beijing.aliyuncs.com/readme/tts-1.jpg" width="200" alt=""> <img src="https://cmbok.oss-cn-beijing.aliyuncs.com/readme/tts-2.jpg" width="200" alt="">

## 离线

漫画按话批量下，打包成 EPUB / CBZ / ZIP / PDF，或就留一个图片文件夹。东西落在你指定的目录里，不藏在应用私有目录。

- 下载去白边：像素级裁掉四周白边再放大，参数存成预设，裁之前先预览
- 后台下载息屏继续；「仅 Wi-Fi」开了之后流量下自动暂停、回 Wi-Fi 自动接上
- 换机搬完目录，点一下「扫描存储找回内容」，下载记录自己认回来

<img src="https://cmbok.oss-cn-beijing.aliyuncs.com/readme/trim.jpg" width="200" alt=""> <img src="https://cmbok.oss-cn-beijing.aliyuncs.com/readme/trim-2.jpg" width="200" alt="">

## 数据

没有账号，数据不过服务器。要多设备同步就自己接 WebDAV，或者指一个本地目录（可以是网盘或 Syncthing 的同步目录）；备份文件能加密码，账号密码这类凭据永远不进备份。

- 局域网 P2P 传书：手机跟手机、手机跟电脑对传
- 配好 SMTP 可以把书推送到 Kindle 或任何收邮件的阅读器

<img src="https://cmbok.oss-cn-beijing.aliyuncs.com/readme/sync.jpg" width="200" alt=""> <img src="https://cmbok.oss-cn-beijing.aliyuncs.com/readme/sync-2.jpg" width="200" alt="">

## 历程与计划

单次读超过十五秒就记一笔：累计时长、连续阅读天数、按自然年铺开的热力图，四款整版分享海报（阅读报告 / 书墙 / 热力图 / 票根）。阅读计划分「读完一本」和「每日阅读」，到点发通知提醒，阅读器里还带番茄钟。

<img src="https://cmbok.oss-cn-beijing.aliyuncs.com/readme/poster.webp" width="360" alt="分享海报"> <img src="https://cmbok.oss-cn-beijing.aliyuncs.com/readme/plan.webp" width="360" alt="阅读计划">

## 主题

八套内置主题，不合意就进主题编辑器自己配一套。「背景」和「系统动画」是两个独立开关，两个都关就是完全静止的界面，适合墨水屏设备。

<p align="center">
  <img src="https://cmbok.oss-cn-beijing.aliyuncs.com/readme/themes-v2.gif" width="820" alt="八套内置主题轮播">
</p>

## 藏起来的功能

软件里有一批不太容易发现的操作，遇到「这个功能怎么没有」的时候，不妨先长按试试：

- 长按底部的「漫画 / 图书」：直接续读最近一次看的那本
- 长按番茄钟：自定义专注时长、循环次数与休息时长
- 阅读器里长按下拉：添加或取消当前位置的书签
- 长按阅读器面板的按钮：拖着换位置
- 书架右边缘左滑：呼出竖型分类导航栏
- 图书与漫画页右上角的按钮：左右滑动切换功能，下滑显示底部按钮
- 漫画聚搜页下拉：切到复搜，多选标签同时搜多个来源

还有一个彩蛋藏在软件里，自己找找看。

---

## 下载

三个平台的安装包都托管在网盘，任选一个顺手的：

| 网盘 | 地址 |
| --- | --- |
| 光鸭云盘 | [点此下载](https://www.guangyapan.com/s/1942586733185413185_apaoPfuQ0RoGwQTM)（无需提取码） |
| 百度网盘 | [点此下载](https://pan.baidu.com/s/1-tYwegrQJtQ3VHVqNOxj1A?pwd=fds7)（提取码 fds7） |
| 夸克网盘 | [点此下载](https://pan.quark.cn/s/c4d45ac3fb57#/list/share)（无需提取码） |
| 迅雷网盘 | [点此下载](https://pan.xunlei.com/s/VOzYJzL8LuhuGwVIkywQBbtSA1?pwd=93na#)（提取码 93na） |
| UC网盘 | [点此下载](https://drive.uc.cn/s/00d2e8642f9d4)（无需提取码） |

iOS 包为未签名 ipa，需用自己的 Apple ID 签名后安装。

## 交流

- **GitHub**：[hlning/cmbok_app](https://github.com/hlning/cmbok_app)
- **Telegram**：[加入群组](https://t.me/+yUxmPm06kHMwYzll)
- **QQ 群**：`1092280445`（若已满，最新群号见软件内「我的」页面）

## 常见问题

**装完之后书架是空的？**
软件本身不带任何内容。本机的书直接导入就能读；在线内容要你自己在「我的」里配好来源，配完搜索页才会有东西。

**换手机怎么把东西搬过去？**
把下载目录整个搬到新设备，在同步设置里恢复一份备份，然后点「扫描存储找回内容」。

**为什么要存储权限？**
下载的漫画和导入的书都放在你自己指定的目录。这样换设备直接搬走，或交给网盘同步，都不用再导出一遍。

**收费吗，以后会加广告吗？**
免费，MIT 开源。没有广告、内购和积分墙，也没有需要登录的账号体系。

## 免责声明

本软件免费开源，仅供个人学习研究与交流，禁止商业用途。软件不提供任何内容，第三方源由使用者自行配置；使用过程中的搜索、阅读、下载等行为均由使用者自主决定并承担相应责任。软件按「现状」提供，不对连续可用性、及时性与安全性作担保。

## 开源协议

本项目基于 [MIT License](https://opensource.org/licenses/MIT) 开源。

Copyright (c) 2026 hlning
