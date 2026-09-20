// wtooltheme.js —— gerrit-gate 的主题插件（PolyGerrit 只允许用插件 + CSS 变量改外观）
//
// 它只做两件事：
//   1. 把 /static/wtool-theme.css 的内容塞进一个 <style> 元素（官方文档明说
//      "可以自己建 <style> 加到 document.head"）—— 那个文件由
//      `gerrit-gate theme <名字>` 生成；
//      注意别用 plugin.styleApi().insertCSSRule()：它只接受**一条**规则，
//      组合主题（compact+dark 是两条）会整段抛错、而且被 catch 吞掉，
//      表现是"主题没生效但也不报错"（踩过）；
//   2. CSS 里如果带 /*wtool:force-dark*/ 标记，就给 <html> 加上 Gerrit 自带的
//      darkTheme 类（配色本身也在那个 CSS 里，见 themes/dark.css）。
//
// 为什么用 /static 而不是把 CSS 直接写死在插件里：
// 换主题只要改一个静态文件、刷新浏览器即可，不用重启 Gerrit，也不用重装插件。
// fetch 带 cache:'no-store'，绕开静态资源 15 分钟的缓存。
Gerrit.install(plugin => {
  const FORCE_DARK = '/*wtool:force-dark*/';

  fetch('/static/wtool-theme.css', {cache: 'no-store'})
    .then(resp => (resp.ok ? resp.text() : ''))
    .then(css => {
      if (!css) return;
      const forceDark = css.indexOf(FORCE_DARK) >= 0;
      const rules = css.split(FORCE_DARK).join('');
      if (rules.trim()) {
        const style = document.createElement('style');
        style.setAttribute('id', 'wtool-theme');
        style.textContent = rules;
        document.head.appendChild(style);
      }
      if (forceDark) {
        const apply = () => {
          document.documentElement.classList.add('darkTheme');
          document.documentElement.classList.remove('lightTheme');
        };
        apply();
        // 用户在设置里切深浅色时，App 会重写 class —— 我们再按主题按回去
        new MutationObserver(apply).observe(document.documentElement, {
          attributes: true,
          attributeFilter: ['class'],
        });
      }
    })
    .catch(() => { /* 拿不到就当没主题，别影响 Gerrit 本身 */ });
});
