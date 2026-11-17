<title>TranslateHUD 划词 Markdown 测试</title>

> 用途：划词翻译时检查「假换行合并 / 空行保留 / 结构标记是否还在」。下面每种格式各试一小段即可。



---



## 一、标题层级



# 一级标题 H1

## 二级标题 H2

### 三级标题 H3

#### 四级标题 H4

##### 五级标题 H5

###### 六级标题 H6



正文普通段落：这是一段普通文字，用来对照标题是否还在、字号/层级标记是否被吃掉。



---



## 二、强调与行内样式



普通字，**粗体**，\*斜体\*，***粗斜体***，\~\~删除线\~\~，`行内代码 path/to/file.swift`。



中英混排：**TranslateHUD** 是菜单栏翻译，\*selection\* 划词与 `OCR` 截图。



---



## 三、空行与段落（重点测空行是否被吞）



第一段：假换行测试前先确认空行。



第二段：上面这一行和本段之间应有一个空行；译完后空行应还在。



第三段：下面列表前也应留空行。



---



## 四、无序列表



- 苹果
- 香蕉
- 樱桃

带空行的列表：



- 第一项
- 第二项（与上一项之间有空行）
- 第三项

嵌套：



- 外层 A

  - 内层 A1
  - 内层 A2
- 外层 B

  - 内层 B1

---





## 五、有序列表



1. 打开 TranslateHUD
2. 划选本段文字
3. 看译文是否仍是 1. 2. 3.

带空行：



1. 步骤一
2. 步骤二（中间空行）
3. 步骤三

---



## 六、引用



> 这是一句引用。
>
> 引用里也可以有第二段，中间应有空行。



嵌套引用：



> 外层引用
>
> 内层引用还在不在？



---



## 七、代码



行内：`let x = 1`



围栏代码（整块一般不应被翻译）：



```Swift
func hello() {
    print("Hello, TranslateHUD")
}
```



围栏前后都有空行与说明：



上面是说明。



```Plain Text
plain fence
line two
```



下面是说明，空行应保留。



---



## 八、链接与图片语法



链接：[官方仓库](https://github.com/jisi71/TranslateHUD)



带标题的链接：[文档](https://example.com/path)



图片语法（只测标记不被拆）：![图标示意](https://example.com/icon.png)



---



## 九、表格



| 功能 | 状态 | 备注 |
|-|-|-|
| 假换行 | 待测 | PDF 软换行 |
| 空行 | 待测 | 段间空行 |
| 列表 | 待测 | `-` / `1.` |



---



## 十、分隔线与任务列表



上文结束。



---



- [x] 已完成的任务

- [ ] 未完成的任务

- [ ] 再试一次划词

---



## 十一、PDF 假换行样例（可整段划）



This is a long English sentence that was

broken in the middle by a narrow column so the

translator used to see three broken lines.



这是一段被版心

打断的中文句子，用来看智能合并是否拼回整句。



英文断词：The implementation of the algo-

rithm should become one word after purify.



---



## 十二、信件式空行



Dear Sir,



I hope you are well.



Best regards,

Yahao



---



## 十三、综合一小段（推荐整段划一次）



## 产品说明



平台级的交易基础设施我们做不了，但可以：



- 在豆包、抖音上开小店，做商品详情页的优化；
- 直接做线索生意：如果你没能力去谈 GEO 大客户，自己做一个垂直平台。比如做一个家教推荐网站，人知道这个平台，再把线索分发给兼职家教老师。

详见 [示例链接](https://example.com) 与代码：



```Plain Text
shop.optimize()
leads.dispatch()
```



完。
