;; ══════════════════════════════════════════════════════════════════
;;  cadcore.lsp — cad-automatic-wwj 的 LISP 核心库
;; ══════════════════════════════════════════════════════════════════
;;
;;  在 accoreconsole 里通过 (load "cadcore.lsp") 加载，然后调用 (c:XXX ...)。
;;
;;  设计原则：
;;    1. 所有函数都以 (c:名字) 形式定义，可直接在 scr 里 (c:名字) 调用。
;;    2. 所有函数返回结构化标记，用 princ 打到 stdout，供 PowerShell 解析：
;;         @@KEY=value@@            单值
;;         <<<KEY ...>>> ... <<<END>>>   块
;;    3. 绘图前强制关闭捕捉与命令回显，否则 accoreconsole 会卡在「指定第一个点」。
;;    4. 任何函数都不假设图纸已存在；先 (c:SETUP) 初始化环境。
;;    5. 绝不弹对话框：FILEDIA/CMDDIA/EXPERT 全部设为无提示模式。
;;
;;  用法（scr 脚本里）：
;;     (setvar "SECURELOAD" 0)
;;     (load "C:/path/to/cadcore.lsp")
;;     (c:SETUP)
;;     (c:LAYER "GEO" 3)
;;     (c:LINE 0 0 100 0)
;;     (c:SAVEAS "C:/out.dwg" "2018")
;; ══════════════════════════════════════════════════════════════════

;; ── 内部工具 ──────────────────────────────────────────────────────

;; 打一个单值标记
(defun cadsay (k v)
  (princ (strcat "\n@@" k "=" (if (= (type v) 'STR) v (vl-princ-to-string v)) "@@"))
  (princ)
)

;; 打一个块标记的开头
(defun cadblk (k v)
  (princ (strcat "\n<<<" k " " (if (= (type v) 'STR) v (vl-princ-to-string v)) ">>>"))
  (princ)
)

(defun cadend () (princ "\n<<<END>>>") (princ))

;; 数字格式化：去掉多余小数位，避免 1.0000000000 这种噪声
;;
;; **只在存在小数点时才剥尾零**。之前无条件 while 剥零，
;; 整数 100 被 rtos 成 "100.000000"，剥完变成 "1"，
;; 于是尺寸标注打出 p2=1,0 —— 图上没错但证据字符串骗人，排查时会被带偏。
(defun cadnum (x / s)
  (setq s (rtos x 2 6))
  (if (vl-string-search "." s)
    (progn
      (while (and (> (strlen s) 1) (= (substr s (strlen s) 1) "0"))
        (setq s (substr s 1 (1- (strlen s))))
      )
      (if (= (substr s (strlen s) 1) ".") (setq s (substr s 1 (1- (strlen s)))))
    )
  )
  s
)

;; 点 → "x,y,z" 字符串
(defun cadpt (p) (strcat (cadnum (car p)) "," (cadnum (cadr p)) "," (cadnum (caddr p))))

;; 列表 → 用分隔符串起来（AutoLISP 没有内置 join）
(defun cadjoin (lst sep / s)
  (setq s "")
  (foreach x lst (if (= s "") (setq s x) (setq s (strcat s sep x))))
  s
)

;; 安全执行一个 command，吞掉返回的 nil
(defun cadcmd (lst / r)
  (setvar "CMDECHO" 0)
  (setq r (apply 'command lst))
  (princ)
)

;; ── 单位 / 空间统计 ───────────────────────────────────────────────
;;
;; ★ 关于图纸空间：accoreconsole **没有布局引擎** ★
;;
;; 实测（AutoCAD 2018 accoreconsole）以下全部不可用：
;;   (layoutlist)                      → no function definition: LAYOUTLIST
;;   (vlax-get-acad-object)            → nil（vl-load-com 也不行）
;;   (member '-LAYOUT (atoms-family 0)) → nil（命令不存在）
;;   (setvar "CTAB" "Layout1")         → AutoCAD 变量设置被拒绝
;;   (tblnext "LAYOUT")                → nil
;;   (tblsearch "LAYOUT" "Layout1")    → 表函数参数无效
;;   (ssget "_X" '((410 . "Model")))   → nil（410 组码不可过滤）
;;
;; 所以这个 skill **只画模型空间**，布局/图纸空间请走 Invoke-CadCom.ps1。
;; 但 (67 . 0) / (67 . 1) 过滤器是可用的，用它区分模型/图纸空间实体。
(defun cadspacecount ( / ss)
  (setq ss (ssget "_X" '((67 . 0))))
  (if ss (sslength ss) 0)
)

;; 图纸空间实体数（正常情况下恒 0，除非打开已有图纸）
(defun cadpapercount ( / ss)
  (setq ss (ssget "_X" '((67 . 1))))
  (if ss (sslength ss) 0)
)

;; 设置单位：(c:UNITS 4) → 毫米
;;   INSUNITS 取值：0 无单位 / 1 英寸 / 2 英尺 / 3 英里 / 4 毫米 / 5 厘米
;;                  6 米 / 7 千米 / 8 微英寸 / 9 密耳 / 10 码
;; **必须判 nil**：实测 (setvar "INSUNITS" nil) 直接抛
;; 「AutoCAD 变量设置被拒绝: "INSUNITS" nil」，整个脚本停在这一行。
(defun cadunits (u / cur)
  (setq cur (getvar "INSUNITS"))
  (cond
    ((null u) (cadsay "UNITS" (strcat "ok=" (itoa cur) " (unchanged)")))
    ((and (numberp u) (>= u 0) (<= u 10))
     (setvar "INSUNITS" u)
     (cadsay "UNITS" (strcat "ok=" (itoa (getvar "INSUNITS")) " was=" (itoa cur)))
    )
    (T (cadsay "UNITS" (strcat "FAILED=invalid:" (vl-princ-to-string u) " keep=" (itoa cur))))
  )
  (princ)
)

;; 单位名 → INSUNITS 码（供 PowerShell 侧对齐，LISP 侧也能查）
(defun cadunitcode (name / s)
  (setq s (strcase (if (= (type name) 'STR) name "")))
  (cond
    ((= s "NONE") 0) ((= s "UNITLESS") 0)
    ((= s "IN") 1) ((= s "INCH") 1) ((= s "INCHES") 1)
    ((= s "FT") 2) ((= s "FEET") 2)
    ((= s "MI") 3) ((= s "MILE") 3) ((= s "MILES") 3)
    ((= s "MM") 4) ((= s "MILLIMETER") 4) ((= s "MILLIMETERS") 4)
    ((= s "CM") 5) ((= s "CENTIMETER") 5)
    ((= s "M") 6) ((= s "METER") 6) ((= s "METERS") 6)
    ((= s "KM") 7) ((= s "KILOMETER") 7)
    ((= s "MIL") 9) ((= s "MILS") 9)
    ((= s "YD") 10) ((= s "YARD") 10)
    (T nil)
  )
)

;; ── 块构建器 ──────────────────────────────────────────────────────
;;
;; **为什么不能用 (command "_.-BLOCK" name pt) 包住一堆画图命令**
;;
;; 直觉写法是开一个 -BLOCK，然后画实体，画完回车收尾，实体就归块了。
;; 但 accoreconsole 里这样一定失败：-BLOCK 给完基点和名字后直接进入
;; 「选择对象:」提示，**它不会进入某种"后续实体自动入块"的状态**。
;; 于是紧接着的 _.CIRCLE 的坐标被 -BLOCK 当成"选择点"吃掉，屏幕上出现
;;     *无效选择*
;;     需要点或窗口(W)/…/单个(SI)
;; 然后整张图卡死到超时，日志里只有一行「; 错误: 函数已取消」。
;;
;; (princ "\n") 也救不了：princ 只往 stdout 打字，不往命令输入队列送回车。
;; -BLOCK 只认真正的回车（""），而 "" 在 (apply 'command ...) 里就是
;; 结束当前命令 —— 问题是这之前它已经拿着错的选择点失败退出了。
;;
;; 可行的做法只有两条：
;;   A. 先画到模型空间，再用选择集一次性喂给 -BLOCK（本函数采用）
;;   B. 全程 entmake：entmake BLOCK → entmake CIRCLE → entmake ENDBLK
;;      B 更"纯"，但要求每个实体都手写 DXF 组码，且样条/齿轮这类复
;;      杂实体没法用 entmake 简便构造，最终还是要走 A。
;;
;; A 的关键是「怎么把块定义期间的实体挑出来」。两种记法：
;;   · 句柄法：画完每个实体 (cadblkadd)，记 (cdr (assoc 5 (entget (entlast))))
;;     缺点：已经被 -BLOCK 吃掉（转进块定义）的实体 handent 取回后
;;     不在当前空间，容易重复计入。
;;   · entnext 游走法：进块前记下 (entlast)，出块后再从它的下一个开始
;;     一路 (entnext) 走到尾 —— 简单、无状态、不会漏也不会重。
;; ──────────────────────────────────────────────────────────────────

;; 进入块定义：记下名字/基点/进入前的最后一个实体
;;   (c:BEGBLOCK "BOLT_M12" 0 0)
(setq *cadblkctx* nil)
(defun c:BEGBLOCK (name x y)
  (setq *cadblkctx* (list name (float x) (float y) (entlast)))
  (princ (strcat "\n@@BEGBLOCK=" name "@@"))
  (princ)
)

;; 退出块定义：把入块后新产生的实体整体转成块
;;   (c:ENDBLOCK)
(defun c:ENDBLOCK ( / name x y prev e ss n)
  (if (null *cadblkctx*)
    (cadsay "ENDBLOCK" "FAILED-no-active-block")
    (progn
      (setq name (car *cadblkctx*))
      (setq x (cadr *cadblkctx*))
      (setq y (caddr *cadblkctx*))
      (setq prev (nth 3 *cadblkctx*))
      (setq ss (ssadd))
      (setq e (if prev (entnext prev) (entnext)))
      (while e
        (ssadd e ss)
        (setq e (entnext e))
      )
      (setq n (sslength ss))
      (if (> n 0)
        (progn
          (cadcmd (list "_.-BLOCK" name (list x y) ss ""))
          (cadsay "ENDBLOCK"
                  (strcat name " n=" (itoa n) " inblock=" (itoa (cadblkcnt name))))
        )
        (cadsay "ENDBLOCK" (strcat name " FAILED-empty"))
      )
      (setq *cadblkctx* nil)
    )
  )
  (princ)
)

;; 数一个块定义里有多少实体（不含 ENDBLK），用来验证块真的建成了
(defun cadblkcnt (name / s e n)
  (setq n 0 s (tblobjname "BLOCK" name))
  (if s
    (progn
      (setq e (entnext s))
      (while (and e (/= (cdr (assoc 0 (entget e))) "ENDBLK"))
        (setq n (1+ n) e (entnext e))
      )
    )
  )
  n
)

;; ══════════════════════════════════════════════════════════════════
;;  c:SETUP —— 环境初始化。任何操作前必须先调用。
;; ══════════════════════════════════════════════════════════════════
(defun c:SETUP ( / )
  (setvar "CMDECHO" 0)
  (setvar "OSMODE" 0)       ; 关捕捉，否则命令行会等「指定第一个点」
  (setvar "3DOSMODE" 0)
  (setvar "SNAPMODE" 0)
  (setvar "ORTHOMODE" 0)
  (setvar "DYNMODE" 0)      ; 关动态输入
  (setvar "FILEDIA" 0)      ; 关文件对话框
  (setvar "CMDDIA" 0)
  (setvar "ATTDIA" 0)
  (setvar "EXPERT" 5)       ; 不追问「是否确实要…」
  (setvar "INSUNITS" 4)     ; 毫米
  (setvar "LUNITS" 2)
  (setvar "LUPREC" 4)
  (setvar "AUNITS" 0)
  (setvar "MEASUREMENT" 1)  ; 公制
  (setvar "PDMODE" 0)
  (setvar "PDSIZE" 0)
  (setvar "GRIDMODE" 0)
  (setvar "MIRRTEXT" 1)
  (setvar "TEXTSTYLE" "Standard")
  (princ "\n@@SETUP=ok@@")
  (princ)
)

;; ══════════════════════════════════════════════════════════════════
;;  c:LAYER —— 建/改图层
;;    (c:LAYER "GEO" 3)       名字 + 颜色号
;;    (c:LAYER "GEO" 3 "DASHED")  再加线型
;; ══════════════════════════════════════════════════════════════════
(defun c:LAYER (name color ltype / tbl rec useLt)
  (setq tbl (tblsearch "LAYER" name))

  ;; 线型必须先确认存在。
  ;; -LAYER 的 _L 选项给一个库里没有的名字时，AutoCAD 只会打一行
  ;; 「未找到线型 xxx」，然后**继续等下一个输入**——而我们已经没输入了，
  ;; 于是整个脚本挂在这一行直到超时，日志里只有「; 错误: 函数已取消」。
  ;; 所以先在 LTYPE 表里查一下，查不到就退回 CONTINUOUS，
  ;; 并在标记里说清楚（用户才知道自己写的线型没生效）。
  (setq useLt "")
  (if (and ltype (> (strlen ltype) 0))
    (if (tblsearch "LTYPE" ltype)
      (setq useLt ltype)
      (setq useLt "CONTINUOUS")
    )
  )

  (if tbl
    (progn
      (setq rec (tblobjname "LAYER" name))
      (entmod (list (cons -1 rec) (cons 62 color)))
    )
    (progn
      (if (> (strlen useLt) 0)
        (cadcmd (list "_.-LAYER" "_M" name "_C" (itoa color) name "_L" useLt name ""))
        (cadcmd (list "_.-LAYER" "_M" name "_C" (itoa color) name ""))
      )
    )
  )

  ;; 回执里带上「请求的线型」与「实际用的线型」，对不上就是被替换了。
  ;; 缺失线型额外打一条 key 唯一的标记 @@LTYPE_MISSING.<图层>=<线型>@@ ——
  ;; 因为 @@LAYER=...@@ 的 key 对所有图层都是 LAYER，多个图层会互相覆盖，
  ;; 最后只剩一行；带图层名的 key 才能一条不漏地被 PowerShell 收集成 warning。
  (if (and ltype (> (strlen ltype) 0) (/= (strcase ltype) (strcase useLt)))
    (progn
      (cadsay "LAYER" (strcat name " color=" (itoa color)
                              " ltype=" useLt " LTYPE_MISSING=" ltype))
      (princ (strcat "\n@@LTYPE_MISSING." name "=" ltype "@@"))
    )
    (cadsay "LAYER" (strcat name " color=" (itoa color)
                            " ltype=" (if (> (strlen useLt) 0) useLt "BYLAYER")))
  )
  (princ)
)

;; ══════════════════════════════════════════════════════════════════
;;  基础图元
;; ══════════════════════════════════════════════════════════════════

;; 直线：(c:LINE x1 y1 x2 y2)
(defun c:LINE (x1 y1 x2 y2 / e)
  (cadcmd (list "_.LINE" (list x1 y1) (list x2 y2) ""))
  (setq e (entlast))
  (cadsay "LINE" (strcat (cadnum x1) "," (cadnum y1) "->" (cadnum x2) "," (cadnum y2)
                         " handle=" (cdr (assoc 5 (entget e)))))
  (princ)
)

;; 多段线：(c:PLINE "0,0" "100,0" "100,50")  —— 点用字符串传，逗号分隔
(defun c:PLINE (p1 p2 p3 p4 p5 p6 p7 p8 p9 p10 / lst n i e)
  (setq lst (list p1 p2 p3 p4 p5 p6 p7 p8 p9 p10) n 0)
  (setq lst (vl-remove-if '(lambda (x) (or (null x) (= x ""))) lst))
  (cadcmd (append (list "_.PLINE") lst (list "")))
  (setq e (entlast))
  (cadsay "PLINE" (strcat "pts=" (itoa (length lst)) " handle=" (cdr (assoc 5 (entget e)))))
  (princ)
)

;; 圆：(c:CIRCLE cx cy r)
(defun c:CIRCLE (cx cy r / e)
  (cadcmd (list "_.CIRCLE" (list cx cy) r))
  (setq e (entlast))
  (cadsay "CIRCLE" (strcat "c=" (cadnum cx) "," (cadnum cy) " r=" (cadnum r)
                           " handle=" (cdr (assoc 5 (entget e)))))
  (princ)
)

;; 圆弧：(c:ARC cx cy r startDeg endDeg)  角度制，逆时针
;; 拆成中间变量而不是一层套一层的 (list (+ cx (* r (cos ...))))：
;; 深层嵌套的括号数量极难数对，一旦少一个就是「参数类型错误: stringp nil」这种
;; 完全不指向真正位置的报错。可读性在这里直接等于可维护性。
(defun c:ARC (cx cy r a1 a2 / e rad1 rad2 p1 p2)
  (setq rad1 (* pi (/ a1 180.0)))
  (setq rad2 (* pi (/ a2 180.0)))
  (setq p1 (list (+ cx (* r (cos rad1))) (+ cy (* r (sin rad1)))))
  (setq p2 (list (+ cx (* r (cos rad2))) (+ cy (* r (sin rad2)))))
  (cadcmd (list "_.ARC" "_C" (list cx cy) p1 p2))
  (setq e (entlast))
  (cadsay "ARC" (strcat "c=" (cadnum cx) "," (cadnum cy) " r=" (cadnum r)
                        " " (cadnum a1) "->" (cadnum a2) " handle=" (cdr (assoc 5 (entget e)))))
  (princ)
)

;; 矩形：(c:RECT x1 y1 x2 y2)
(defun c:RECT (x1 y1 x2 y2 / e)
  (cadcmd (list "_.RECTANG" (list x1 y1) (list x2 y2)))
  (setq e (entlast))
  (cadsay "RECT" (strcat (cadnum x1) "," (cadnum y1) "->" (cadnum x2) "," (cadnum y2)
                         " handle=" (cdr (assoc 5 (entget e)))))
  (princ)
)

;; 椭圆：(c:ELLIPSE cx cy rx ry)
(defun c:ELLIPSE (cx cy rx ry / e)
  (cadcmd (list "_.ELLIPSE" "_C" (list cx cy) (list (+ cx rx) cy) ry))
  (setq e (entlast))
  (cadsay "ELLIPSE" (strcat "c=" (cadnum cx) "," (cadnum cy) " rx=" (cadnum rx) " ry=" (cadnum ry)
                            " handle=" (cdr (assoc 5 (entget e)))))
  (princ)
)

;; 点：(c:POINT x y)
(defun c:POINT (x y / e)
  (cadcmd (list "_.POINT" (list x y)))
  (setq e (entlast))
  (cadsay "POINT" (strcat (cadnum x) "," (cadnum y) " handle=" (cdr (assoc 5 (entget e)))))
  (princ)
)

;; 样条曲线：(c:SPLINE "0,0" "50,80" "100,0")
(defun c:SPLINE (p1 p2 p3 p4 p5 / lst e)
  (setq lst (vl-remove-if '(lambda (x) (or (null x) (= x ""))) (list p1 p2 p3 p4 p5)))
  (cadcmd (append (list "_.SPLINE") lst (list "" "" "")))
  (setq e (entlast))
  (cadsay "SPLINE" (strcat "pts=" (itoa (length lst)) " handle=" (cdr (assoc 5 (entget e)))))
  (princ)
)

;; ══════════════════════════════════════════════════════════════════
;;  文字与标注;; ══════════════════════════════════════════════════════════════════

;; 单行文字：(c:TEXT x y height "内容")  以左下角为基点
(defun c:TEXT (x y h txt / e)
  (cadcmd (list "_.TEXT" "_J" "_BL" (list x y) h 0.0 txt))
  (setq e (entlast))
  (cadsay "TEXT" (strcat "at=" (cadnum x) "," (cadnum y) " h=" (cadnum h)
                         " s=" txt " handle=" (cdr (assoc 5 (entget e)))))
  (princ)
)

;; 居中文字：(c:TEXTC x y h "内容")
(defun c:TEXTC (x y h txt / e)
  (cadcmd (list "_.TEXT" "_J" "_MC" (list x y) h 0.0 txt))
  (setq e (entlast))
  (cadsay "TEXTC" (strcat "at=" (cadnum x) "," (cadnum y) " s=" txt
                          " handle=" (cdr (assoc 5 (entget e)))))
  (princ)
)

;; 多行文字：(c:MTEXT x y w h "内容")
;;
;;   **为什么用 entmake 而不是 (command "_.MTEXT" ...)**
;;   MTEXT 走命令行时，指定完角点会弹出「多行文字编辑器」对话框；
;;   accoreconsole 没有 UI，对话框永远出不来，命令就悬在那里不返回。
;;   实测表现是后续命令被吞、stdout 只剩一行「; 错误: 函数已取消」。
;;   entmake 直接写 AcDbMText，不经过任何交互。
;;
;;   组码：10=插入点 40=字高 41=参考宽度 71=附着点(1=左上)
;;         72=书写方向(5=按样式) 1=文字内容 7=文字样式 50=旋转角
(defun c:MTEXT (x y w h txt / e)
  (setq e (entmake
    (list '(0 . "MTEXT") '(100 . "AcDbEntity") (cons 8 (getvar "CLAYER"))
          '(100 . "AcDbMText")
          (cons 10 (list x y 0))
          (cons 40 h)
          (cons 41 w)
          '(71 . 1)
          '(72 . 5)
          (cons 1 txt)
          (cons 7 (getvar "TEXTSTYLE"))
          '(50 . 0.0)
    )
  ))
  (if e
    (cadsay "MTEXT" (strcat "at=" (cadnum x) "," (cadnum y)
                            " w=" (cadnum w) " h=" (cadnum h)
                            " s=" txt
                            " handle=" (cdr (assoc 5 (entget (entlast))))))
    (cadsay "MTEXT" "FAILED-entmake-nil")
  )
  (princ)
)

;; ══════════════════════════════════════════════════════════════════
;;  标注
;;
;;  **为什么三个标注函数全部用 entmake，而不是 (command "_.DIMLINEAR" ...)**
;;
;;  实测（accoreconsole 2018，中文版）：
;;    DIMLINEAR / DIMALIGNED / DIMRADIUS 走 command 通道时，选择阶段的行为
;;    和桌面版不一致 ——
;;      · DIMRADIUS 把 ename 当第一个参数传进去，它仍然提示「选择圆弧或圆」，
;;        连 ename、pickfirst 预选、拾取点三种写法全部失败，最后回
;;        "*无效选择* 需要单个对象" 并取消整个命令；
;;      · 更要命的是「取消」会把 **同一 LISP 里后续所有 command 一起吞掉**，
;;        所以一次标注失败 = 后面整张图都画不出来，而 stdout 只留一行
;;        「; 错误: 函数已取消」，极难定位。
;;    entmake 是直接往数据库里塞实体，完全不走命令行交互，因此：
;;      稳定、可复现、失败立刻返回 nil（能当场判断），也不会吞掉后续命令。
;;  代价是要自己填 DXF 组码，字段含义写在每个函数上方。
;; ══════════════════════════════════════════════════════════════════

;; 线性（水平/垂直自动）标注：(c:DIMLIN x1 y1 x2 y2 tx ty)
;;   组码：10=尺寸线定义点 11=文字中点 70=0(旋转型) 13/14=两条尺寸界线原点
;;
;;   ★ 50 组码（旋转角）必须按两点几何自动判定，绝不能写死 0 ★
;;   原来这里固定 '(50 . 0)，于是「竖向标注」的尺寸线被强制水平，
;;   AutoCAD 量出来的 42 组码（实际测量值）是两点在水平方向的投影差 ——
;;   竖直边 0→120 实测得到 0.0，图上直接印出一个「0」。
;;   这不是显示问题，是标注真实值就错了。
;;   判据：两点水平跨度 >= 垂直跨度 → 水平标注(rot=0)；
;;         否则 → 垂直标注(rot=pi/2)，此时量的是 y 投影差。
(defun c:DIMLIN (x1 y1 x2 y2 tx ty / e rot dx dy)
  (setq dx (abs (- x2 x1)))
  (setq dy (abs (- y2 y1)))
  (if (>= dx dy)
    (setq rot 0.0)
    (setq rot (/ pi 2.0))
  )
  (setq e (entmake
    (list '(0 . "DIMENSION") '(100 . "AcDbEntity") (cons 8 (getvar "CLAYER"))
          '(100 . "AcDbDimension")
          (cons 10 (list tx ty 0))
          (cons 11 (list tx ty 0))
          '(70 . 0)
          '(1 . "")
          (cons 3 (getvar "DIMSTYLE"))
          '(100 . "AcDbAlignedDimension")
          (cons 13 (list x1 y1 0))
          (cons 14 (list x2 y2 0))
          (cons 50 rot)
          '(100 . "AcDbRotatedDimension"))))
  (if e
    (cadsay "DIMLIN" (strcat "p1=" (cadnum x1) "," (cadnum y1)
                             " p2=" (cadnum x2) "," (cadnum y2)
                             " rot=" (cadnum (/ (* rot 180.0) pi))
                             " handle=" (cdr (assoc 5 (entget (entlast))))))
    (cadsay "DIMLIN" "FAILED-entmake-nil"))
  (princ)
)

;; 对齐标注：(c:DIMALIGN x1 y1 x2 y2 tx ty)
;;   与线性标注的区别：不带 AcDbRotatedDimension，50 组码取两点连线角度
;;
;;   ★ 实测：52 组码（倾斜角）与 AcDbRotatedDimension 尾都会让 entmake
;;     静默返回 nil —— 不报错、不提示，只是画不出来。★
;;   四个变体在 accoreconsole 2018 上的实测结果：
;;     · 50 + 52 + 无 Rotated 尾  → nil
;;     · 仅 50                    → ok
;;     · 无 50 无 52              → ok（但角度按默认，斜线标注会歪）
;;     · 50 + RotatedDimension 尾 → nil
;;   所以这里只保留 50，绝不加 52，也绝不加 RotatedDimension 尾。
;;   这正是它与 DIMLIN 的分界：DIMLIN 要 50=0 + Rotated 尾（正交），
;;   DIMALIGN 要真实角度 50 + 无尾（沿两点方向）。
(defun c:DIMALIGN (x1 y1 x2 y2 tx ty / e ang)
  (setq ang (angle (list x1 y1) (list x2 y2)))
  (setq e (entmake
    (list '(0 . "DIMENSION") '(100 . "AcDbEntity") (cons 8 (getvar "CLAYER"))
          '(100 . "AcDbDimension")
          (cons 10 (list tx ty 0))
          (cons 11 (list tx ty 0))
          '(70 . 1)
          '(1 . "")
          (cons 3 (getvar "DIMSTYLE"))
          '(100 . "AcDbAlignedDimension")
          (cons 13 (list x1 y1 0))
          (cons 14 (list x2 y2 0))
          (cons 50 ang))))
  (if e
    (cadsay "DIMALIGN" (strcat "angle=" (cadnum (/ (* ang 180.0) pi))
                               " handle=" (cdr (assoc 5 (entget (entlast))))))
    (cadsay "DIMALIGN" "FAILED-entmake-nil"))
  (princ)
)

;; 半径标注：(c:DIMRAD cx cy ex ey tx ty)
;;   70=4 表示半径型；15=圆/弧上的定义点（就是边缘点 ex,ey）；40=引线长度
;;
;;   ★ 10 组码是「圆心」，不是文字点 ★
;;   原来写成 (10 . 文字点)，AutoCAD 就把「文字点到圆周点的距离」当半径量：
;;   圆心 100,60 / 半径 45 / 文字点 150,112 实测 42 组码 = 52.2398，
;;   图上印出 R52.24 —— 差 7.24mm，装不上。
;;   正确组码分工：
;;     10 = 圆心 (cx,cy)      ← AcDbDimension 的定义点，半径标注里就是圆心
;;     11 = 文字中点 (tx,ty)  ← 文字摆哪儿只由它决定
;;     15 = 圆周上的点 (ex,ey)
(defun c:DIMRAD (cx cy ex ey tx ty / e r)
  (setq r (distance (list cx cy) (list ex ey)))
  (setq e (entmake
    (list '(0 . "DIMENSION") '(100 . "AcDbEntity") (cons 8 (getvar "CLAYER"))
          '(100 . "AcDbDimension")
          (cons 10 (list cx cy 0))
          (cons 11 (list tx ty 0))
          '(70 . 4)
          '(1 . "")
          (cons 3 (getvar "DIMSTYLE"))
          '(100 . "AcDbRadialDimension")
          (cons 15 (list ex ey 0))
          '(40 . 0))))
  (if e
    (cadsay "DIMRAD" (strcat "c=" (cadnum cx) "," (cadnum cy)
                             " r=" (cadnum r)
                             " edge=" (cadnum ex) "," (cadnum ey)
                             " handle=" (cdr (assoc 5 (entget (entlast))))))
    (cadsay "DIMRAD" "FAILED-entmake-nil"))
  (princ)
)

;; ══════════════════════════════════════════════════════════════════
;;  填充
;; ══════════════════════════════════════════════════════════════════

;; 边界填充：(c:HATCH "ANSI31" 1.0 px py)
;;
;;   ★ -HATCH 的参数顺序是最容易写错的一处 ★
;;   原来写成 (list "_.-HATCH" "_P" pat scale "0" "_S" (list px py) "" "")，
;;   结果 hatch 根本没创建，而 (entlast) 拿回的是上一个实体的 handle
;;   （证据里 DIMRAD 与 HATCH 报同一个 handle，极具迷惑性）。
;;   根因：_S 是 Select objects，后面必须跟选择集或对象，给点坐标无效。
;;
;;   正确做法（实测 hatchCount 0→1，handle 为新值）：
;;     1) 用 setvar 把图案/比例/角度设好（HPNAME / HPSCALE / HPANG）；
;;     2) -HATCH 后面直接给内部点，不要 _S。
;;   注意 setvar 的 HPSCALE 是实数，命令行给 "0" 也能接受，但统一用实数更稳。
(defun c:HATCH (pat scale px py / e ss)
  (setvar "HPNAME" pat)
  (setvar "HPSCALE" (float scale))
  (setvar "HPANG" 0.0)
  (cadcmd (list "_.-HATCH" (list px py) ""))
  ;; 用选择集数一遍，别只信 (entlast) —— 创建失败时 entlast 会返回上一个实体
  (setq ss (ssget "_X" '((0 . "HATCH"))))
  (setq e (entlast))
  (if (and ss (> (sslength ss) 0) e (= (cdr (assoc 0 (entget e))) "HATCH"))
    (cadsay "HATCH" (strcat "pat=" pat " scale=" (cadnum scale)
                            " count=" (itoa (sslength ss))
                            " handle=" (cdr (assoc 5 (entget e)))))
    (cadsay "HATCH" "FAILED-no-hatch-created"))
  (princ)
)

;; 实体填充：(c:SOLID x1 y1 x2 y2 x3 y3 x4 y4)
(defun c:SOLID (x1 y1 x2 y2 x3 y3 x4 y4 / e)
  (cadcmd (list "_.SOLID" (list x1 y1) (list x2 y2) (list x3 y3) (list x4 y4) ""))
  (setq e (entlast))
  (cadsay "SOLID" (strcat "handle=" (cdr (assoc 5 (entget e)))))
  (princ)
)

;; ══════════════════════════════════════════════════════════════════
;;  编辑操作（对最后一次选择集或全部实体）
;; ══════════════════════════════════════════════════════════════════

;; 全选并操作：(c:MOVEALL dx dy)
(defun c:MOVEALL (dx dy / ss)
  (setq ss (ssget "_X"))
  (if ss (cadcmd (list "_.MOVE" ss "" (list 0 0) (list dx dy))))
  (cadsay "MOVEALL" (strcat "n=" (if ss (itoa (sslength ss)) "0")))
  (princ)
)

;; 按类型选：(c:SSBYTYPE "LINE") → 返回选择集
(defun c:SSBYTYPE (typ / ss)
  (setq ss (ssget "_X" (list (cons 0 typ))))
  ss
)

;; 删除某类型全部实体：(c:DELTYPE "LINE")
(defun c:DELTYPE (typ / ss n)
  (setq ss (ssget "_X" (list (cons 0 typ))))
  (setq n (if ss (sslength ss) 0))
  (if ss (cadcmd (list "_.ERASE" ss "")))
  (cadsay "DELTYPE" (strcat typ " n=" (itoa n)))
  (princ)
)

;; 删除某图层全部实体：(c:DELLAYER "GEO")
(defun c:DELLAYER (lay / ss n)
  (setq ss (ssget "_X" (list (cons 8 lay))))
  (setq n (if ss (sslength ss) 0))
  (if ss (cadcmd (list "_.ERASE" ss "")))
  (cadsay "DELLAYER" (strcat lay " n=" (itoa n)))
  (princ)
)

;; ══════════════════════════════════════════════════════════════════
;;  模板底图相关
;; ══════════════════════════════════════════════════════════════════

;; 只保留指定图层：(c:BASELAYERS (list "GEO" "TEXT" "DIM"))
;;
;; 用途：模板里往往带着几十个用不上的图层（Defpoints、各种标注样式层、
;; 别的项目留下的层），一份新图只需要其中几个。这里把不在清单里的图层
;; 上的实体删掉、再把空图层 PURGE 掉。
;;
;; ★ 为什么必须先把实体删掉再 PURGE ★
;;   PURGE 只删「空」图层；还有实体挂着的层删不掉，会静默留下。
;;   先 ERASE 该层实体 → 层空了 → PURGE 才真的生效。
;; ★ 为什么 0 层和当前层不能删 ★
;;   PURGE 0 层会被拒绝；删当前层会让后续绘制报错。两者都跳过并留标记。
(defun c:BASELAYERS (keep / tbl rec lay drop n dropped)
  (setq tbl (tblnext "LAYER" T))
  (setq drop '())
  (while tbl
    (setq lay (cdr (assoc 2 tbl)))
    (if (and (/= lay "0")
             (/= lay (getvar "CLAYER"))
             (not (member lay keep)))
      (setq drop (cons lay drop))
    )
    (setq tbl (tblnext "LAYER"))
  )
  (setq dropped 0)
  (foreach lay drop
    (c:DELLAYER lay)
    (setq dropped (1+ dropped))
    ;; PURGE 空图层。命令不认名字时只会提示一行就继续，不会挂住。
    (cadcmd (list "_.PURGE" "_LA" lay "_N"))
  )
  (cadsay "BASELAYERS" (strcat "kept=" (itoa (length keep)) " purged=" (itoa dropped)))
  (princ)
)

;; 模板实体统计：(c:BASEINFO)
;;   模板模式下用来把「模板自带多少实体」和「新画了多少」分开报告。
(defun c:BASEINFO ( / ss)
  (setq ss (ssget "_X"))
  (cadsay "BASEINFO" (strcat "entities=" (itoa (if ss (sslength ss) 0))))
  (princ)
)

;; 复制：(c:COPYLAST dx dy)
(defun c:COPYLAST (dx dy / e)
  (setq e (entlast))
  (cadcmd (list "_.COPY" e "" (list 0 0) (list dx dy) ""))
  (cadsay "COPYLAST" (strcat "handle=" (cdr (assoc 5 (entget (entlast))))))
  (princ)
)

;; 旋转：(c:ROTATEALL deg)
(defun c:ROTATEALL (deg / ss)
  (setq ss (ssget "_X"))
  (if ss (cadcmd (list "_.ROTATE" ss "" (list 0 0) deg)))
  (cadsay "ROTATEALL" (strcat "deg=" (cadnum deg)))
  (princ)
)

;; 缩放：(c:SCALEALL factor)
(defun c:SCALEALL (f / ss)
  (setq ss (ssget "_X"))
  (if ss (cadcmd (list "_.SCALE" ss "" (list 0 0) f)))
  (cadsay "SCALEALL" (strcat "f=" (cadnum f)))
  (princ)
)

;; 镜像：(c:MIRRORALL x1 y1 x2 y2 [keep])
(defun c:MIRRORALL (x1 y1 x2 y2 keep / ss ans)
  (setq ss (ssget "_X"))
  (setq ans (if (= keep "1") "_Y" "_N"))
  (if ss (cadcmd (list "_.MIRROR" ss "" (list x1 y1) (list x2 y2) ans)))
  (cadsay "MIRRORALL" (strcat "keep=" ans))
  (princ)
)

;; 阵列：(c:ARRAYRECT rows cols dr dc)
(defun c:ARRAYRECT (r c dr dc / ss)
  (setq ss (ssget "_X"))
  (if ss (cadcmd (list "_.-ARRAY" ss "" "_R" r c dr dc)))
  (cadsay "ARRAYRECT" (strcat "rows=" (itoa r) " cols=" (itoa c)))
  (princ)
)

;; 偏移：(c:OFFSET dist)
(defun c:OFFSET (d / e)
  (setq e (entlast))
  (cadcmd (list "_.OFFSET" d e ""))
  (cadsay "OFFSET" (strcat "d=" (cadnum d) " handle=" (cdr (assoc 5 (entget (entlast))))))
  (princ)
)

;; 倒角：(c:FILLET r)
(defun c:FILLET (r / )
  (setvar "FILLETRAD" r)
  (cadcmd (list "_.FILLET" "_P" (ssget "_X")))
  (cadsay "FILLET" (strcat "r=" (cadnum r)))
  (princ)
)

;; 炸开全部：(c:EXPLODEALL)
(defun c:EXPLODEALL ( / ss)
  (setq ss (ssget "_X"))
  (if ss (cadcmd (list "_.EXPLODE" ss)))
  (cadsay "EXPLODEALL" (strcat "n=" (if ss (itoa (sslength ss)) "0")))
  (princ)
)

;; ══════════════════════════════════════════════════════════════════
;;  块操作
;; ══════════════════════════════════════════════════════════════════

;; 把当前选择（按类型）定义为块：(c:MAKEBLOCK "BLK1" "CIRCLE")
;; 把当前空间里某一类实体整体做成块
;;   (c:MAKEBLOCK "CIRCLES" "CIRCLE")
(defun c:MAKEBLOCK (name typ / ss)
  (setq ss (ssget "_X" (list (cons 0 typ))))
  (if ss
    (progn
      (cadcmd (list "_.-BLOCK" name (list 0 0) ss ""))
      (cadsay "MAKEBLOCK" (strcat name " from=" typ " n=" (itoa (sslength ss))
                                 " inblock=" (itoa (cadblkcnt name))))
    )
    (cadsay "MAKEBLOCK" (strcat name " FAILED-no-entities"))
  )
  (princ)
)

;; 插入块：(c:INSERTBLOCK "BLK1" x y sx sy rot)
(defun c:INSERTBLOCK (name x y sx sy rot / e)
  (cadcmd (list "_.-INSERT" name (list x y) sx sy rot))
  (setq e (entlast))
  (cadsay "INSERTBLOCK" (strcat name " at=" (cadnum x) "," (cadnum y)
                                " handle=" (cdr (assoc 5 (entget e)))))
  (princ)
)

;; ══════════════════════════════════════════════════════════════════
;;  查询（只读）
;; ══════════════════════════════════════════════════════════════════

;; 实体总数
(defun c:COUNT ( / ss)
  (setq ss (ssget "_X"))
  (cadsay "COUNT" (if ss (itoa (sslength ss)) "0"))
  (princ)
)

;; 按类型统计：块输出 <<<TYPESTAT ...>>>
(defun c:TYPESTAT ( / ss i e typ tbl keys k v)
  (setq ss (ssget "_X") tbl '())
  (if ss
    (progn
      (setq i 0)
      (repeat (sslength ss)
        (setq e (ssname ss i) typ (cdr (assoc 0 (entget e))))
        (setq tbl (if (assoc typ tbl)
                    (subst (cons typ (1+ (cdr (assoc typ tbl)))) (assoc typ tbl) tbl)
                    (append tbl (list (cons typ 1)))))
        (setq i (1+ i))
      )
    )
  )
  (cadblk "TYPESTAT" (strcat "n=" (itoa (length tbl))))
  (foreach pr tbl
    (princ (strcat "\n" (car pr) "=" (itoa (cdr pr))))
  )
  (cadend)
  (princ)
)

;; 图层清单：块输出 <<<LAYERS ...>>>
(defun c:LAYERLIST ( / tbl rec lay col i)
  (cadblk "LAYERS" "list")
  (setq tbl (tblnext "LAYER" T) i 0)
  (while tbl
    (setq lay (cdr (assoc 2 tbl)) col (cdr (assoc 62 tbl)))
    (princ (strcat "\n" lay "|" (itoa col)))
    (setq i (1+ i))
    (setq tbl (tblnext "LAYER"))
  )
  (cadend)
  (cadsay "LAYERCOUNT" (itoa i))
  (princ)
)

;; 图形范围：EXTMIN/EXTMAX
(defun c:EXTENTS ( / mn mx)
  (command "_.ZOOM" "_E")
  (setq mn (getvar "EXTMIN") mx (getvar "EXTMAX"))
  (cadsay "EXTMIN" (cadpt mn))
  (cadsay "EXTMAX" (cadpt mx))
  (cadsay "WIDTH" (cadnum (- (car mx) (car mn))))
  (cadsay "HEIGHT" (cadnum (- (cadr mx) (cadr mn))))
  (princ)
)

;; 逐实体清单（限前 N 个）：块输出 <<<ENTLIST ...>>>
;;   (c:ENTLIST 200)
(defun c:ENTLIST (maxn / ss i e ed cnt)
  (setq ss (ssget "_X"))
  (setq cnt (if ss (sslength ss) 0))
  (cadblk "ENTLIST" (strcat "total=" (itoa cnt)))
  (if ss
    (progn
      (setq i 0)
      (while (and (< i cnt) (< i maxn))
        (setq e (ssname ss i) ed (entget e))
        (princ (strcat "\n"
          (cdr (assoc 0 ed)) "|"
          (if (assoc 8 ed) (cdr (assoc 8 ed)) "-") "|"
          (if (assoc 5 ed) (cdr (assoc 5 ed)) "-") "|"
          (if (assoc 10 ed) (cadpt (cdr (assoc 10 ed))) "-") "|"
          (if (assoc 40 ed) (cadnum (cdr (assoc 40 ed))) "-")
        ))
        (setq i (1+ i))
      )
    )
  )
  (cadend)
  (princ)
)

;; 单值查询：(c:GETVAR "INSUNITS")
(defun c:GETVAR (n)
  (cadsay (strcat "VAR_" n) (vl-princ-to-string (getvar n)))
  (princ)
)

;; 图纸摘要：一次拿到常用信息
(defun c:SUMMARY ( / ss mn mx)
  (setq ss (ssget "_X"))
  (cadsay "SUMMARY_COUNT" (if ss (itoa (sslength ss)) "0"))
  (cadsay "SUMMARY_DWGNAME" (getvar "DWGNAME"))
  (cadsay "SUMMARY_DWGPREFIX" (getvar "DWGPREFIX"))
  (cadsay "SUMMARY_INSUNITS" (itoa (getvar "INSUNITS")))
  (cadsay "SUMMARY_LIMCHECK" (itoa (getvar "LIMMIN")))
  (setq mn (getvar "EXTMIN") mx (getvar "EXTMAX"))
  (cadsay "SUMMARY_EXTMIN" (cadpt mn))
  (cadsay "SUMMARY_EXTMAX" (cadpt mx))
  (princ)
)

;; ══════════════════════════════════════════════════════════════════
;;  存盘 / 导出 / 清理
;; ══════════════════════════════════════════════════════════════════

;; 存 DWG：(c:SAVEAS "C:/out.dwg" "2018")
;;   实测：目标文件已存在会停在「此名称的图形已存在」，所以先删。
(defun c:SAVEAS (path ver / full)
  (setq full path)
  (if (findfile full) (vl-file-delete full))
  (if (> (strlen ver) 0)
    (cadcmd (list "_.SAVEAS" ver full))
    (cadcmd (list "_.SAVEAS" full))
  )
  (if (findfile full)
    (cadsay "SAVEAS" (strcat "ok=" full " size=" (itoa (vl-file-size full))))
    (cadsay "SAVEAS" (strcat "FAILED=" full))
  )
  (princ)
)

;; 存 DXF：(c:SAVEDXF "C:/out.dxf" "2013")
;;
;; ★ 版本控制的关键（实测 AutoCAD 2018 / accoreconsole）★
;;
;; 直接 `_.DXFOUT 路径 版本串` **不会切换版本** —— 第二个参数是「小数精度」，
;; 三种写法 "12"/"13"/"16" 导出的结果全是 AC1032（2018 自身格式），
;; 只是文件大小略有差异（精度不同），极具迷惑性。
;;
;; 真正的版本开关藏在「精度」提示的选项里：
;;   _.DXFOUT "path"
;;   >> 输入精度的小数位数 (0 到 16) 或 [二进制(B)/选择对象(O)/预览(P)/版本(V)] <16>:
;; 于是正确序列是：文件名 → _V → 版本名 → 精度 → 二进制。
;;
;; 实测对应关系（用文件头 AC10xx 校验，不是看提示回显）：
;;   R12  → AC1009  (7,783 字节)
;;   2000 → AC1015  (214,619 字节)
;;   2004 → AC1018
;;   2007 → AC1021
;;   2010 → AC1024
;;   2013 → AC1027  (125,759 字节)
;;   2018 → AC1032
;;
;; ★ 别为 2018 抄近路（已踩过）★
;;   曾经写成「2018 是当前格式，省掉 _V 两步直接 DXFOUT」——错。
;;   本机 AutoCAD 2018 的 DXFOUT 默认输出格式是 **2013**（AC1027），
;;   不是 2018。省掉 _V 的结果是：请求 2018、实得 AC1027，文件看着
;;   没问题（能打开、实体齐全），只有比对文件头才看得出来。所以
;;   2018 也必须走 _V 分支，一个特例都不留。
(defun c:SAVEDXF (path ver prec / full v p)
  (setq full path
        v    (if (and ver (> (strlen ver) 0)) ver "2018")
        p    (if (and prec (> (strlen prec) 0)) prec "16")
  )
  (if (findfile full) (vl-file-delete full))
  (cadcmd (list "_.DXFOUT" full "_V" v p))
  (if (findfile full)
    (cadsay "SAVEDXF" (strcat "ok=" full " ver=" v " size=" (itoa (vl-file-size full))))
    (cadsay "SAVEDXF" (strcat "FAILED=" full " ver=" v))
  )
  (princ)
)

;; 打印到 PDF：(c:PLOTPDF "C:/out.pdf" "A3")
;;
;; **accoreconsole 里没有 EXPORTPDF 命令**（实测回「未知命令"PDF"」），
;; 出 PDF 只能走 -PLOT + "DWG To PDF.pc3" 设备。
;;
;; -PLOT 的提示序列是严格固定的 15 步，多一个少一个都会错位到别的提示上
;; （错位后 AutoCAD 会把 "_M" 当成命令名，吐一串「未知命令"M"」，且不报错退出）：
;;   1 详细配置?      _Y
;;   2 布局名         Model
;;   3 输出设备       DWG To PDF.pc3
;;   4 图纸尺寸       <尺寸全名，见下表>
;;   5 图纸单位       _M(毫米) / _I(英寸)
;;   6 图形方向       _L(横向) / _P(纵向)
;;   7 上下颠倒       _N
;;   8 打印区域       _E(范围) / _D(显示) / _L(图形界限) / _W(窗口)
;;   9 打印比例       _F(布满)
;;  10 打印偏移       _C(居中)
;;  11 按样式打印     _Y
;;  12 打印样式表     monochrome.ctb / "" 表示无
;;  13 打印线宽       _Y
;;  14 着色打印       _A(按显示)
;;  15 文件名         <完整路径>
;;  16 保存页面设置   _N
;;  17 继续打印       _Y
;;
;; 图纸尺寸必须用**全名**（"ISO A3 (420.00 x 297.00 毫米)"），
;; 只写 "A3" 会被当成无效输入，回落到默认的 ANSI A，图会被缩得很小。
(defun cadpaper (size / s)
  (setq s (strcase size))
  (cond
    ((= s "A4") "ISO A4 (297.00 x 210.00 毫米)")
    ((= s "A3") "ISO A3 (420.00 x 297.00 毫米)")
    ((= s "A2") "ISO A2 (594.00 x 420.00 毫米)")
    ((= s "A1") "ISO A1 (841.00 x 594.00 毫米)")
    ((= s "A0") "ISO A0 (1189.00 x 841.00 毫米)")
    ((= s "A")  "ANSI A (11.00 x 8.50 英寸)")
    ((= s "B")  "ANSI B (17.00 x 11.00 英寸)")
    ((= s "C")  "ANSI C (22.00 x 17.00 英寸)")
    ((= s "D")  "ANSI D (34.00 x 22.00 英寸)")
    ((= s "E")  "ANSI E (44.00 x 34.00 英寸)")
    ;; 没匹配上就原样透传，允许调用方直接给全名
    (T size)
  )
)

(defun c:PLOTPDF (path size / full paper)
  (setq full path)
  (setq paper (cadpaper (if (> (strlen size) 0) size "A3")))
  (if (findfile full) (vl-file-delete full))
  (cadcmd (list "_.-PLOT"
                "_Y"                        ; 1  详细打印配置
                "Model"                     ; 2  布局
                "DWG To PDF.pc3"            ; 3  输出设备
                paper                       ; 4  图纸尺寸（全名）
                "_M"                        ; 5  毫米
                "_L"                        ; 6  横向
                "_N"                        ; 7  不倒置
                "_E"                        ; 8  打印范围 = 范围
                "_F"                        ; 9  布满
                "_C"                        ; 10 居中
                "_Y"                        ; 11 按样式打印
                "monochrome.ctb"            ; 12 打印样式表
                "_Y"                        ; 13 打印线宽
                "_A"                        ; 14 着色 = 按显示
                full                        ; 15 输出文件名
                "_N"                        ; 16 不保存页面设置
                "_Y"                        ; 17 继续打印
          ))
  (if (findfile full)
    (cadsay "PLOTPDF" (strcat "ok=" full " paper=" paper " size=" (itoa (vl-file-size full))))
    (cadsay "PLOTPDF" (strcat "FAILED=" full " paper=" paper))
  )
  (princ)
)

;; 清理未用对象：(c:PURGEALL)
(defun c:PURGEALL ( / )
  (cadcmd (list "_.-PURGE" "_A" "*" "_N"))
  (cadsay "PURGEALL" "done")
  (princ)
)

;; 图形检查：(c:AUDIT)
(defun c:AUDIT ( / )
  (cadcmd (list "_.AUDIT" "_Y"))
  (cadsay "AUDIT" "done")
  (princ)
)

;; 缩放到范围：(c:ZOOMEXT)
(defun c:ZOOMEXT ( / )
  (cadcmd (list "_.ZOOM" "_E"))
  (cadsay "ZOOMEXT" "done")
  (princ)
)

;; 重生成：(c:REGENALL)
(defun c:REGENALL ( / )
  (cadcmd (list "_.REGENALL"))
  (cadsay "REGEN" "done")
  (princ)
)

;; 选择集 → 面积总和（对闭合多段线/圆）
(defun c:AREA ( / ss i e a tot)
  (setq ss (ssget "_X") tot 0.0 i 0)
  (if ss
    (repeat (sslength ss)
      (setq e (ssname ss i))
      (setq a (vl-catch-all-apply 'vla-get-Area (list (vlax-ename->vla-object e))))
      (if (not (vl-catch-all-error-p a)) (setq tot (+ tot a)))
      (setq i (1+ i))
    )
  )
  (cadsay "AREA" (cadnum tot))
  (princ)
)

;; ══════════════════════════════════════════════════════════════════
;;  参数化几何（常用工程图形）
;; ══════════════════════════════════════════════════════════════════

;; 齿轮示意：(c:GEAR cx cy r teeth)
(defun c:GEAR (cx cy r n / i a r1 r2 p1 p2 lst)
  (setq i 0 lst '())
  (setq r1 r r2 (* r 0.85))
  (while (< i (* n 2))
    (setq a (* pi (/ i n)))
    (setq p1 (list (+ cx (* (if (= (rem i 2) 0) r1 r2) (cos a)))
                   (+ cy (* (if (= (rem i 2) 0) r1 r2) (sin a)))))
    (setq lst (append lst (list p1)))
    (setq i (1+ i))
  )
  (cadcmd (append (list "_.PLINE") (mapcar '(lambda (p) (list (car p) (cadr p))) lst) (list "_C")))
  (cadsay "GEAR" (strcat "c=" (cadnum cx) "," (cadnum cy) " r=" (cadnum r) " teeth=" (itoa n)
                         " handle=" (cdr (assoc 5 (entget (entlast))))))
  (princ)
)

;; 正多边形：(c:POLYGON cx cy r sides)
(defun c:POLYGON (cx cy r n / )
  (cadcmd (list "_.POLYGON" n (list cx cy) "_C" r))
  (cadsay "POLYGON" (strcat "n=" (itoa n) " r=" (cadnum r)
                            " handle=" (cdr (assoc 5 (entget (entlast))))))
  (princ)
)

;; 中心线十字：(c:CENTERLINE cx cy len)
(defun c:CENTERLINE (cx cy len / h)
  (setq h (/ len 2.0))
  (cadcmd (list "_.LINE" (list (- cx h) cy) (list (+ cx h) cy) ""))
  (cadcmd (list "_.LINE" (list cx (- cy h)) (list cx (+ cy h)) ""))
  (cadsay "CENTERLINE" (strcat "c=" (cadnum cx) "," (cadnum cy) " len=" (cadnum len)))
  (princ)
)

;; 矩形阵列钻孔示意：(c:BOLTPATTERN cx cy r count)
(defun c:BOLTPATTERN (cx cy r n / i a px py)
  (setq i 0)
  (while (< i n)
    (setq a (* 2 pi (/ (float i) n)))
    (setq px (+ cx (* r (cos a))) py (+ cy (* r (sin a))))
    (cadcmd (list "_.CIRCLE" (list px py) 3.0))
    (setq i (1+ i))
  )
  (cadcmd (list "_.CIRCLE" (list cx cy) r))
  (cadsay "BOLTPATTERN" (strcat "c=" (cadnum cx) "," (cadnum cy) " r=" (cadnum r) " n=" (itoa n)))
  (princ)
)

(princ "\n@@CADCORE=loaded@@")
(princ)
