# 主题（CSS 变量）

PolyGerrit **只允许用 CSS 变量改外观**，官方说法见 Gerrit 的
`Documentation/pg-plugin-dev.html`（"Gerrit only offers customized CSS styling
by setting custom_properties"）。

* `compact.css` —— 只动密度：字号/行高/间距/圆角/阴影。**一个颜色都不动**，
  所以和浅色、深色、以及用户自己的深浅色偏好都能共存。
* `dark.css` —— Gerrit 自带深色配色。文件头那行 `/*wtool:force-dark*/` 是给插件看的
  标记：有它就把 `<html>` 切成 `darkTheme`。配色本体是从 polygerrit 的
  深色主题里原样取的（364 个变量），所以不会有"深色下某块还是白的"这种事。
* `high-contrast.css` —— 黑白高对比，只作用在 `html.lightTheme` 下。

组合：`gerrit-gate theme compact+dark` 会把两段按顺序拼起来。

## dark.css 是怎么来的（怎么重新生成）

```sh
# 1. 从站点上把前端 bundle 抓下来
curl -s http://127.0.0.1:8080/elements/gr-app.js -o /tmp/grapp.js
# 2. 找到深色那段（第二处 --primary-text-color: 所在的规则块），把声明掏出来
#    套进 html.darkTheme { ... }，前面加 /*wtool:force-dark*/
# 3. Gerrit 升级后想刷新配色就重做一遍
```

（这个文件是一次性生成后提交进 git 的，不随 Gerrit 版本自动变。）
