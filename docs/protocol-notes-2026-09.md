# UCAS 协议抓包笔记（2026-09-05）

> 通过 CDP（Chrome DevTools Protocol）对 sep.ucas.ac.cn 真实登录流程抓包分析得出。
> 抓包环境：`chrome --remote-debugging-port=9222 --user-data-dir=<独立profile>`，Node 直连 CDP Network domain。

---

## 一、SEP 登录协议变更

### 1.1 完整登录链路（已验证）

```
① 新设备手机验证（可能触发）
   POST /user/doUserVisitPhone
   参数: userId=<AES加密>&userName=<AES加密>&mobile=<AES加密手机号>
         &yzPhone=<短信验证码>&trustDevice=1&sbPhone=y
   → 303 → /

② 登录
   POST /slogin
   参数: userName=<邮箱>&pwd=<RSA-2048加密,344字符base64>
         &loginFrom=<空>&certCode=<4位验证码>&sb=sb
   → 303 → /appStore → 303 → /sepCard/toCard → 303 → /sepCard/card

③ Session = 单个 JSESSIONID Cookie（无其他 token）
```

### 1.2 问题与修法

| # | 问题 | 位置 | 修法 |
|---|------|------|------|
| 1 | SEP 重定向已从 302 改为 **303**，`validateSession` 只查 302，靠兜底逻辑碰巧正确 | `sep_authentication_service.dart:102` | `status == 302 \|\| status == 303` |
| 2 | 新设备手机验证流程（doUserVisitPhone）App 未实现，触发时只报「登录失败」 | `sep_authentication_service.dart` 错误提取 | 错误信息识别该状态，提示「请先在浏览器登录一次并信任设备」 |
| 3 | `validateSession` 拉整个 HTML 页面，慢 | `_validationPath = '/portal/site/226/821'` | 改用轻量 JSON 接口（见 1.3），非登录态返回登录页特征 |

### 1.3 登录后可用的干净 JSON API（JSESSIONID 即可）

| 接口 | 数据 | 用途 |
|------|------|------|
| `GET /sepCardData/headData` | 姓名/研究所/学号/手机/邮箱/身份类型 | 用户信息、**轻量 session 验证** |
| `GET /sepCardData/dataScore` | 学位课学分进度（要求 vs 已修） | 学分查询新功能 |
| `GET /sepCardData/summaryCounts` | 待办/通知计数 | 角标 |
| `GET /getCalendarList?year=&month=` | 校历 | 校历展示 |

---

## 二、选课系统域名问题（"每学期失效"的根源）

### 2.1 现状（2026-09-05 实测 + App 实际运行验证）

| 系统 | 域名 | 状态（App 实测） |
|------|------|------|
| 成绩/考试/讲座/课程详情 | `jwxk.ucas.ac.cn` | ✅ **正常**（勿动） |
| 课表/抢课（xkgo） | `xkgo.ucas.ac.cn:3000` | ✅ **9月门户仍指向它** |
| 课表/抢课（秋季猜测域名） | `xkgodj.ucas.ac.cn` | ❌ App 按月猜 8-12 月用它 → **本学期猜错** |
| 新选课系统 | `xkcts.ucas.ac.cn:8443` | 🆕 门户 siteId 226 指向的新系统（未来迁移方向） |

**结论：只有课表坏了**。根因是 `xkgo_authentication_service.dart` 按月份猜域名（9月猜成 xkgodj），且 L151 把真实发现的域名又覆盖成了猜测值。

**门户实测入口拓扑**（sepCard/card 课程学习 Tab 的按钮）：

| 按钮 | 入口 | 落地 |
|------|------|------|
| 所有课程 | `/portal/site/524/xs/1/{XOR加密token}` | `xkgo:3000/course/personSchedule` |
| 我的课程 | `/portal/siteToUrl/441/001?toUrl=https://mooc.ucas.edu.cn/courselist/mycourse` | 超星 mooc |
| 课表 | `/portal/siteToUrl/441/001?toUrl=https://kb.mooc.ucas.edu.cn/res/pc/curriculum/schedule.html` | 超星课表 |
| 已选课程详情/课程评估 | `/portal/site/226/xs/1/1/{token}` | xkcts:8443 |

> 注：`jwxk.ucas.ac.cn/courseManage/selectedCourse` 无会话访问会经 `/redirect` 弹回 SEP 门户——这是它正常的 SSO 引导流程，**不代表系统下线**。

### 2.2 新系统登录机制（Identity 令牌）

```
① SEP 登录态下 GET https://sep.ucas.ac.cn/portal/site/226/821
② 返回 HTML 中含（meta refresh + location.href 双写）：
   https://xkcts.ucas.ac.cn:8443/login?Identity=<uuid>&roleId=821
   ↑ Identity 每次访问页面动态生成，一次性
③ GET 该 URL → 303 → /main → 会话建立
```

> `/portal/site/226/821` 是「学生角色」入口，`roleId=821` 即 siteId。
> 门户页是学校的官方间接层——**学校换域名时只改这个页面的跳转目标**。

---

## 三、持久化方案（核心）

### 3.1 原则：入口动态发现，不硬编码域名

```
SEP 登录
  → GET /portal/site/226/821
  → 正则提取 href="(https://[^"]+/login\?Identity=[^"]+)"
  → 得到当前选课系统 baseUrl（本学期=xkcts:8443，未来再换也不怕）
  → GET Identity URL 跟随 303 建立会话
```

### 3.2 学期自动检测（termId 机制）

`/course/termSchedule` 页面的 `<select name="termId">`：

- 全量学期列表（1999 → 2026-2027），如 `89576=2026—2027学年(秋)第一学期`
- `selected` 的 option 即**当前学期** → 每次登录自动检测学期切换
- 历史学期数据可按 termId 查询 → 课表可按学期回看

当前学期映射：`89576=2026秋`、`89577=2027春`、`89578=2027夏`、`84069=2026夏`…

### 3.3 存储改造

| 现状 | 问题 | 改法 |
|------|------|------|
| `cache_schedule` 单槽位 | 新学期覆盖旧学期 | 按 `cache_schedule_{termId}` 分键，支持历史回看 |
| `termStartDate` 硬编码 `2026-03-02` | 每学期手动改设置 | 学期切换自动检测（termId 变化）→ 提醒用户确认开学日期；开学日期可从校历/学期接口辅助推断 |
| Cookie 仅内存 CookieJar | 重启即失效 | 可接受（有自动重登），或换 PersistCookieJar |
| XKGO 域名按月份猜 + L151 把发现的真域名覆盖掉 | 换域名即失效 | 整个替换为 3.1 的动态发现 |

### 3.4 App 代码修改点清单（2026-09-05 已实施 ✅）

1. ✅ **`xkgo_authentication_service.dart`**
   - 修复核心 bug：`_establishCourseSystemSession` 现在保留门户真实发现的域名，月份猜测仅作兜底
   - `validateSession` 兼容 303
2. ✅ **`sep_authentication_service.dart`**
   - `validateSession` 兼容 303
   - 识别设备短信验证流程（yzPhone/doUserVisitPhone），给出可操作提示
3. ⏸️ **`jwxk_authentication_service.dart` 不动**——成绩/考试/讲座实测正常
4. 🔮 备选（未来学校真迁移到 xkcts 时再做）：
   - `jwxk` 域名改从 `/portal/site/226/821` 动态发现（该页含 `login?Identity=<uuid>&roleId=821` 链接，其 origin 即新域名）
   - 课表按 `termId` 分键存储（`/course/termSchedule` 的 termId 下拉框含 1999→今全量学期，selected 即当前学期）

---

## 四、抓包基础设施（复用）

- Chrome 启动：`"C:\Program Files\Google\Chrome\Application\chrome.exe" --remote-debugging-port=9222 --user-data-dir="C:/Users/wirs/chrome-cdp-profile" --no-first-run`
- Node REPL 内：`createWS()`（node:net 手写 WebSocket）→ CDP `Network.enable` + `Page.navigate`，重定向链合并保留原始 POST 数据，XHR/Fetch/Document 响应体自动抓取
- 辅助函数：`capList(filter)` 列请求、`capDetail(i)` 看详情、`cdp(method, params)` 发任意 CDP 命令
