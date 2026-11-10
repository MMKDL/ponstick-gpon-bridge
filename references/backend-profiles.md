# 路由器后台协议与页面结构（ZTE / RAISECOM 系）

本文记录在中国移动定制路由器（型号如 **DR5364**，厂商 RAISECOM/中兴平台）上逆向出的后台协议与页面结构，用于**用脚本自动化配置 PPPoE**，避免手动点。

> ⚠️ 通用性有限：固件不同则路径可能变。**先用浏览器手工走一遍**（网络 → 宽带设置），确认页面结构一致，再写脚本。

---

## 1. 平台指纹

```
HTTP Server: Boa/0.94.13          ← ZTE/RAISECOM 定制设备常见
登录页:       /cgi-bin/index2.asp
主页:         /cgi-bin/content.asp   （frameset）
静态 JS:      /JS/menu.js  /JS/util.js  /JS/printtable.js  /JS/jquery-1.8.3.min.js
字符集:       GB2312（读页面要转码）
Cookie:       SESSIONID=boasid<hex>
```

## 2. 登录协议（明文，无盐）

```bash
# 1) 取会话
curl -s -c jar -b jar -o /dev/null http://<ROUTER_IP>/cgi-bin/index2.asp
# 2) 提交登录
curl -s -c jar -b jar -b "UID=<user>; PSW=<password>" \
  -X POST http://<ROUTER_IP>/cgi-bin/index2.asp \
  --data-urlencode "Logoff=0" \
  --data-urlencode "hLoginTimes=1" \
  --data-urlencode "hLoginTimes_Zero=0" \
  --data-urlencode "value_one=1" \
  --data-urlencode "Username1=<user>"  --data-urlencode "Username2=<user>" \
  --data-urlencode "Password1=<pwd>"  --data-urlencode "Password2=<pwd>" \
  --data-urlencode "logintype=usr" \
  --data-urlencode "LoginFailTime=1" --data-urlencode "hLoginFailTime=1" \
  --data-urlencode "Username=<user>"  --data-urlencode "Password=<pwd>"
# 3) 验证
curl -s -b jar -o /dev/null -w "%{http_code}" http://<ROUTER_IP>/cgi-bin/content.asp
#    200 = 登录成功；401 = 失败
```

### 失败原因怎么区分
登录失败时返回体里会多出一行 JS 状态码：
```
userlogin(2); userPSWST(1); gotomain_set();
```
- **`userPSWST(1)` 出现 → 用户名正确、密码错**
- 只有 `userlogin(2)` → 用户名可能都不对
- 有 `userlogin(3)` / 其它 → 可能是**已达最大连接数**（设备限制单账号单会话，先在别的浏览器里登出）

### 常见坑
- 用 **GUI 真实点击**（浏览器里填表单点「登录」）成功率远高于 curl。curl 失败时先别换密码，**换个方式试**（页面未就绪、Referer/UA 校验、单会话限制）。
- 设备有 `LoginFailTime` 计数，**不要盲试密码组合**，容易把自己锁在外面。

## 3. 页面结构

```
content.asp  (frameset)
 ├── refresh.asp      ← 定时刷新
 └── sta-device.asp   ← 主内容（菜单 + 设备信息）
       菜单: 状态 / 网络 / 安全 / 应用 / 管理 / 诊断 / 帮助
       每个菜单项: <a href="javascript:LoadPage('N')">
       LoadPage 定义在 /JS/menu.js → location = MenuArray[N].Link
```
→ **想找某个配置页，最快的办法是读 `/JS/menu.js` 里的 `MenuArray` 映射表**，例如：

| 菜单 | 页面 |
|---|---|
| 状态 → 设备信息 | `/cgi-bin/sta-device.asp` |
| 状态 → 网络侧信息 | `/cgi-bin/sta-network.asp`（**WAN 连接列表在这**） |
| 网络 → 宽带设置 | `/cgi-bin/net-wanset.asp`（**PPPoE 表单在这**） |
| 网络 → LAN 侧地址配置 | `/cgi-bin/net-lan.asp` 之类，按 MenuArray 为准 |
| 管理 → 设备管理 | 按 MenuArray |

**菜单项的 id/name 即文件名**：`MakeMenu_L2()` 里用 `menu_link.lastIndexOf("/")` 与 `indexOf(".asp")` 截出文件名当 id。

## 4. 宽带设置页（net-wanset.asp）表单结构

```
<FORM name=ConfigForm action="/cgi-bin/net-wanset.asp" method="post">
```

| 控件 | 含义 |
|---|---|
| `wanId` | 要编辑的连接（`0|1_INTERNET_R_VID_`、`8|2_OTHER_B_VID_` …） |
| `wanMode` | `Route` / `Bridge` |
| `serviceList` | `INTERNET` / `IPTV` |
| `linkMode` | `linkDHCP` / `linkStatic` / `linkPPP` |
| `bridgeMode` | `PPPoE_Bridged` / `IP_Bridged` |
| `VLANMode` | `UNTAG` / `TAG`（TAG 时另有 `vlan` 输入框填 VLAN ID） |
| `MTU` | 1280-1492 |
| `IpMode` (radio) | `DHCP` / `Static` / `PPPoE` / `PPPoA` / `IPoA` |
| `IpVersion` (radio) | `IPv4` / `IPv6` / `IPv4/IPv6` |
| `pppUserName` / `pppPassword` / `pppServerName` | PPPoE 凭据（密码在 `type=password`） |
| `cb_nat` + `nat` | NAT 开关 |
| `dslitemode` (radio) | 拨号账号类型（`0` = 用户名+密码） |
| `pppDialButton` | 「手动拨号」按钮 → `ManualCntSubmit()` |
| 隐藏 `Wan_Flag` | 决定提交语义（`1`/`5`/`6`/`7`/`8`/`9`/`11`…） |
| 隐藏 `AddFlag` / `isSave` | `false` = 编辑现有连接；`isSave` 非 0 时 `btnSave` 直接 return |
| 按钮 `btnSave10` | `onclick="btnSave(0);"` = 宽带设置的「确定」 |

## 5. 用脚本提交保存

`btnSave(0)` 内部有多处 `alert()`，在自动化环境会抛 `Uncaught`。两个办法：

**A. 兜住 alert 再调用**（推荐，走官方完整流程）
```js
var fr = document.getElementsByName("contentfrm")[0];   // frameset 里定位主 frame
var w = fr.contentWindow;
w.__alerts = [];
w.alert = function (m) { w.__alerts.push(String(m)); };
try { w.btnSave(0); } catch (e) { /* 忽略 */ }
// 之后读 w.__alerts 就能拿到校验提示
```

**B. 直接 POST 表单**（跳过前端校验，字段不全时有风险）
```js
var dd = fr.contentDocument, fd = [];
[...dd.querySelectorAll("input,select,textarea")].forEach(function (el) {
  var n = el.name || el.id; if (!n) return;
  if (el.type === "radio" || el.type === "checkbox") { if (!el.checked) return; }
  fd.push(n + "=" + encodeURIComponent(el.value));
});
var x = new XMLHttpRequest();
x.open("POST", "/cgi-bin/net-wanset.asp", false);
x.setRequestHeader("Content-Type", "application/x-www-form-urlencoded");
x.send(fd.join("&"));
```

## 6. 用 CDP 驱动（web-access skill）要点

```bash
# 新开标签（URL 走 POST body，避免 query 被切分）
curl -s -X POST --data-raw 'http://<ROUTER_IP>/cgi-bin/index2.asp' http://localhost:3456/new
# 读 frame 内容（顶层页面里拿不到 frame 的 DOM，要走 contentDocument）
curl -s -X POST "http://localhost:3456/eval?target=$TID" \
  -d 'var f=document.getElementsByName("contentfrm")[0];f.contentDocument.body.innerText'
```
- 登录页要**先 `navigate` 一次再填表**（页面未就绪时点击无效）
- 菜单链接在 frame 内，`/click` 的顶层选择器**找不到**，要在 frame 上下文里 `a.click()`
- `btnSave` 这类函数在 frame 的全局作用域里，用 `fr.contentWindow.btnSave(0)` 调用

## 7. WAN 连接列表 / 状态页（sta-network.asp）

「广域网络信息」表格由 `printtable.js` 动态渲染，数据来自页面内的 `Wan_*` 数组：

```js
pvc_counts, Wan_WanName[], Wan_Actives[], Wan_Status[], Wan_IP[],
Wan_GateWay[], Wan_IPVERSION[], Wan_UserName[], CurAPMode, EthernetState
```
判读：
- `Wan_Actives[i] == "Yes"` → 该连接启用
- 表格里「连接状态」列显示 **已连接 + IP 地址** → 拨号成功
- `CurAPMode` = `Route` / `Bridge`（软件工作模式）
