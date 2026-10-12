import Foundation
import WebKit

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// 登录方式。用户点「登录」之后先挑一种，模态窗里就**只留对应的那半页**。
///
/// 为什么要有这一层：B 站那个桌面版登录页是左右两栏（左边扫码、右边账号），
/// 模态窗比它窄，两栏一起看就是两边都看不清。与其让用户自己往左推着找，
/// 不如先在菜单里问一句，然后把不相关的那一半整个藏掉。
public enum LoginMode: String, CaseIterable, Identifiable, Sendable {

    /// 只留左边：二维码。
    case qr
    /// 只留右边：账号密码 / 短信 / 第三方。
    case account

    public var id: String { rawValue }

    /// 菜单上那一行。
    public var title: String {
        switch self {
        case .qr: return "二维码登录"
        case .account: return "账号登录"
        }
    }

    /// 这一种要**保留**的那半页（页面自己的类名）。其余的元素，包括另一侧，
    /// 全都归零 —— 怎么藏的见 `LoginPageStyle`。
    var soloSelector: String {
        switch self {
        case .qr: return ".main__left"
        case .account: return ".main__right"
        }
    }

    /// 留下的那半页**本体**有多宽（px）。
    ///
    /// 量出来的，不是估的：藏掉另一半之后，控件就贴着卡片左边缘，
    /// 宽度是它自己定死的这个数。`LoginPageStyle` 拿它算外边距，把控件摆到窗口中间。
    var controlWidth: Int {
        switch self {
        case .qr: return 386
        case .account: return 402
        }
    }
}

public extension WKWebView {

    /// 把登录窗**内容区的底色钉成纯白**。
    ///
    /// 不设的话底下会露出一条灰的。原因量过：这个页面自己只有 340 上下高
    ///（藏掉另一半之后就这么点内容），窗口比它高时下面那一条**没有任何网页
    /// 元素**，命中测试落回 `html`，而 `html` 是透明的 —— 那一块实际是
    /// WKWebView 的 `underPageBackgroundColor` 在涂。它**默认值正好是
    /// `#f6f7f8`**（读出来是 0.9647 / 0.9686 / 0.9725），跟页面 `body`
    /// 那个浅灰一模一样：网页是有意做成"灰底白卡"的，只是我们只留半页，
    /// 白卡之外那圈灰就落到了窗口里。深色模式下它还会跟着变深，
    /// 于是这半扇窗的颜色随系统漂移。
    ///
    /// 所以三处一起设：页面底下的那层、滚动视图、以及 webView 自己的底色。
    /// 页面 `html` 是透明的，滚到头往回拉时的橡皮筋区露出来的是后两者。
    func pinContentBackgroundToWhite() {
        #if canImport(UIKit)
        isOpaque = true
        backgroundColor = .white
        scrollView.backgroundColor = .white
        underPageBackgroundColor = .white
        #else
        underPageBackgroundColor = .white
        #endif
    }
}

/// 登录网页里那点改动：**只留选中的那半页**，外加把底色钉成纯白
///（iOS 还要把输入框字号抬到 16px，见 `script` 里那三条）。
///
/// 摆在 BiliUI 而不是各端各写一份：iOS 的 `LoginSheet` 和 mac 的 `MacLoginSheet`
/// 装的是**同一段脚本**，抄两份的话改一处忘一处，迟早漂移。
///
/// 就这三条 —— 页面本身的排版、留白、页头页脚全都不动，那是 B 站自己的样子。
/// 这里也一个字都碰不到输入框里的内容：App 永远不碰账号密码。
public enum LoginPageStyle {

    /// 造一段**常驻**的用户脚本，塞进 `WKUserContentController` 里。
    ///
    /// `atDocumentEnd`：等 DOM 出来再插，`<head>` 肯定在。
    /// `forMainFrameOnly`：登录页里万一有 iframe，不去动它。
    ///
    /// - Parameter raisesInputFont: 要不要把表单控件的字号抬到 16px。
    ///   **iOS 要开**（不开的话点输入框时页面会被自动放大一点），mac 上没这回事。
    ///   为什么是这个办法，见 `script` 里的第 3 条。
    /// - Parameter appTopMargin: 给 `#app` 顶上留多少 px，**0 表示不设**。
    ///   mac 那块网页上面没有标题栏，控件会贴着窗口上沿，给 30 提一口气；
    ///   iOS 上头顶就是导航栏，不用再留。
    public static func userScript(for mode: LoginMode,
                                  raisesInputFont: Bool,
                                  appTopMargin: Int) -> WKUserScript {
        let source = script(soloSelector: mode.soloSelector,
                            controlWidth: mode.controlWidth,
                            raisesInputFont: raisesInputFont,
                            appTopMargin: appTopMargin)
        return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    /// 脚本本身：把 `soloSelector` 那半页之外的东西全藏掉。
    ///
    /// **用 CSS，不 `.remove()` 节点**：删节点有风险 —— 页面自己的脚本回头
    /// 要是去拿这些元素、拿到 null 再读属性，整页 JS 就崩在那儿了。
    /// `display: none` 一样不占位置、一样点不到，却不可能弄坏别的东西。
    ///
    /// 写 `<style>` 而不是逐个元素改 style：这样**什么时候出现什么时候算**，
    /// 页面自己后补上来的（Vue 渲染、客户端路由换页）也一并盖住；每次整页
    /// 导航脚本都会再跑一遍（`WKUserScript` 是常驻的）。
    private static func script(soloSelector: String,
                               controlWidth: Int,
                               raisesInputFont: Bool,
                               appTopMargin: Int) -> String {
        // 注进网页的那点样式，一条条列在这儿 —— 这就是"我们到底动了页面什么"的全集。
        //
        // 1. `.bd-solo`：被剥下去的那些（见下面的 `solo()`）。
        // 2. `html, body` 的底色：这页是有意做成"灰底白卡"的（`body` 是 #f6f7f8），
        //    藏掉另一半之后卡片下边就空出一条灰的。那条灰**是网页自己画的**，
        //    跟模态窗的底色无关 —— 网页内容比窗口矮，`body` 那 340 高的底色就铺到
        //    340 为止，剩下的空档才是外面那层（`underPageBackgroundColor`，那边已经
        //    被 `pinContentBackgroundToWhite()` 设成白的了）。证据：往上拉网页，
        //    灰条会跟着内容一起被拉走，底下露出来的是白的。所以两边都得白：
        //    外面那层管"拉出来的空档"，这里管"网页自己那 340"。
        // 3. 表单控件的字号（**只有 iOS 加**）：在 iPhone 上点进输入框时，页面会被
        //    自动放大一点。触发条件是**被聚焦控件的计算字号 < 16px**（不是 meta
        //    viewport，也不是能不能捏合），而这页的输入框是 14px，正好中招。
        //    viewport 那条路（`user-scalable=no` / `maximum-scale=1`）在 iOS 上
        //    并不可靠，而且会把用户自己的缩放一起禁掉；抬字号等于把触发条件去掉。
        //    量过：这一条**不改任何布局** —— 控件和输入框的矩形一个像素都没动，
        //    只是框里的字大了两号。mac 上没有这个自动放大，所以那边不加。
        var css = ".bd-solo { display: none !important; }"
            + "html, body { background-color: #ffffff !important; }"
        if raisesInputFont {
            css += "input, textarea, select { font-size: 16px !important; }"
        }

        return """
        (function () {
          var style = document.createElement('style');
          style.textContent = '\(css)';
          (document.head || document.documentElement).appendChild(style);

          // 只留下 SOLO 那一棵子树，其余全藏。
          //
          // 做法是**沿祖先链往上，把每一层的兄弟都藏掉** —— "除了 X 之外
          // 的所有元素"没法直接表达（祖先藏了 X 也就没了），只能这样一层层剥。
          // 注意是藏兄弟、不是删，也不动祖先：所以 X 原来在什么容器里、
          // 靠什么居中，全都还成立。
          var SOLO = '\(soloSelector)';

          // 验证码面板必须放行 —— 它是**弹层**，不是登录页排版的一部分。
          //
          // 手机号登录点「获取验证码」时，B 站会拉起 geetest 的滑块验证
          //（`.geetest_panel` / `.geetest_wind` 那一套）：那些节点是插在
          // 页面最外层的，跟登录卡片的两栏没有半点关系。而我们这套"除了这半页
          // 全藏"是**沿祖先链一路藏到 body** 的 —— 一藏就把它一起藏了，
          // 而且用的是 `!important`，连它自己用来显示的内联样式都压不过。
          // 结果就是：验证码永远弹不出来，手机号登录整条路废掉。
          //
          // 判据用 [class*=] 而不是逐个类名：它内部还有一堆 .geetest_xxx 的
          // 子节点，外面有时还套一层壳，两头这么写就都盖住了。
          var OVERLAY = '[class*="geetest"], [id*="geetest"]';

          // 这一棵子树里有没有验证码面板。命中就整棵别动 —— 宁可多留一块，
          // 也不能把用户唯一能过验证的那扇窗给关了。
          function isOverlay(el) {
            if (!el || !el.querySelector) return false;
            if (el.matches && el.matches(OVERLAY)) return true;
            return !!el.querySelector(OVERLAY);
          }

          // 把留下的那半页摆到窗口中间，顺手把撑宽度的两层收到控件那么宽。
          //
          // 这页里撑宽度的是两个写死的数：`#app` 有 `min-width: 1100px`，
          // 卡片 `.login_wp` 自己有 900 宽。藏掉一半之后控件只剩 386 / 402，
          // 这两个数就全变成了**控件右边那一大块空白** —— 文档比窗口宽出
          // 五六百，手指往右一推就是一片空的（量过：390 宽的窗口里文档能滚到 900）。
          //
          // 所以分两步把这两层都收到控件宽：
          //   1. `#app` 定成控件宽，左边距 = (窗口宽 - 控件宽) / 2 —— 页面就
          //      只剩这么宽了，控件正好落在窗口中间；
          //   2. 卡片那 900 是它**自己**的宽度，光收 `#app` 它照样往右探出去，
          //      所以把它的 width / min-width 松开（auto / 0），让它跟着 `#app`
          //      缩到控件宽。padding / margin 也一并归零：它原来那圈留白是给
          //      "整页"用的，这里只剩半页。
          //
          // 量过的结果：窗口 600 / 820 / 1100，扫码和账号两种，控件居中偏差都是 0，
          // 文档宽度跟窗口**一样宽**（横向溢出 0）。窄到比控件还窄时（比如 390 的
          // 窗口装账号那 402）`#app` 的左边距会变成负数，两边各切一点 —— 也就是
          // "尽量居中"：控件本身就比窗口宽，这个没法再好了。
          //
          // 每次窗口变都得重算（转屏、iPad 分屏拖动、mac 拉窗口），所以挂在 resize
          // 上，另外每次 `solo()` 之后也跟着算一遍 —— 页面是 Vue 渲染的，
          // 这几层会被换掉重建。
          var CONTROL_W = \(controlWidth);

          // 顶上给 `#app` 留多少 px（0 = 不设，见 `userScript` 的说明）
          var APP_TOP = \(appTopMargin);

          function layout() {
            var vw = document.documentElement.clientWidth || window.innerWidth;
            var appEl = document.getElementById('app');
            if (appEl) {
              // 有 min-width 卡着，只写 width 是收不下来的，两个都得写
              if (appEl.style.width !== CONTROL_W + 'px') {
                appEl.style.minWidth = CONTROL_W + 'px';
                appEl.style.width = CONTROL_W + 'px';
              }
              if (appEl.style.marginLeft !== ((vw - CONTROL_W) / 2) + 'px') {
                appEl.style.marginLeft = ((vw - CONTROL_W) / 2) + 'px';
              }
              // 0 是假值，正好等于"不设"：不传的那端连样式都不碰
              if (APP_TOP && appEl.style.marginTop !== APP_TOP + 'px') {
                appEl.style.marginTop = APP_TOP + 'px';
              }
            }
            var card = document.querySelector('.login_wp, #login_wp');
            if (card) {
              if (card.style.padding !== '0px') card.style.padding = '0';
              if (card.style.margin !== '0px') card.style.margin = '0';
              if (card.style.width !== 'auto') card.style.width = 'auto';
              if (card.style.minWidth !== '0px') card.style.minWidth = '0';
            }
          }

          function solo() {
            var keep = document.querySelector(SOLO);
            if (!keep) return;   // 这半页还没渲染出来 / 页面改版了：那就保持原样
            var marked = document.querySelectorAll('.bd-solo');
            for (var i = 0; i < marked.length; i++) marked[i].classList.remove('bd-solo');
            var node = keep;
            while (node && node.parentElement) {
              var siblings = node.parentElement.children;
              for (var j = 0; j < siblings.length; j++) {
                var sib = siblings[j];
                // head 里有刚插进去的那张样式表，藏了它整套规则就全废了
                if (sib === node || sib.tagName === 'HEAD') continue;
                if (isOverlay(sib)) continue;
                sib.classList.add('bd-solo');
              }
              node = node.parentElement;
            }
            layout();
          }

          solo();
          window.addEventListener('resize', layout);
          document.addEventListener('DOMContentLoaded', solo);
          // 这页是 Vue 渲染的，那半页什么时候出来说不准；DOM 一动就再剥一次。
          // 只盯 childList：剥的动作是改 class，不算 childList，所以不会自己
          // 触发自己，转不成死循环。
          new MutationObserver(solo).observe(document.documentElement, {
            childList: true,
            subtree: true
          });
        })();
        """
    }
}
