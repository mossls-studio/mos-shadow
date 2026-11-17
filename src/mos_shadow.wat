;; mos_shadow — EffectCraft effect plug-in (ABI 1)
;; 方向轴投影：一条基线（axis_start → axis_end）把图层轮廓压平，第三个点
;; （aim）给出阴影的方向与长度；离基线越远越模糊、越透明。
;;
;; 几何
;;   A,B   基线两端（buffer px）
;;   L     unit(B-A)
;;   C     第三个点
;;   M     基线中点 (A+B)/2
;;   W     C-M               阴影方向 + 长度
;;   N     perp(L)，朝向 W 的一侧
;;   wn    dot(W,N) > 0      阴影在 N 方向的长度
;;   wu    dot(W,L)          W 沿基线的切向分量（产生斜切）
;;
;;   源像素 P 到基线的有符号高度 h=dot(P-A,N)。扫描源得到 hmin/hmax；
;;   anchor=离 0 更近的一端，far=另一端，span=far-anchor。
;;   源点 P 投到阴影点 Q：
;;     t=(h-anchor)/span
;;     Q=A + u*L + t*W，u=dot(P-A,L)
;;   逆映射（输出 Q 求源 P）：
;;     t=dot(Q-A,N)/wn
;;     h=anchor+t*span
;;     u=dot(Q-A,L)-t*wu
;;     P=A+u*L+h*N
;;   这样阴影贴着基线开始，沿 W 拉伸，长度就是 |W|；t∈[0,1]。
;;
;; 渐进模糊
;;   先把阴影 alpha 采样进 SH；填的时候同时把半径写进 RAD。
;;   再做水平/垂直两遍变半径 box blur：
;;     r(t)=maxBlur * smoothstep(blur_start, blur_end, t)
;;   每行/列维护滑动窗口，半径随 t 连续变化。
;;
;; 合成
;;   sa = SH * opacity * (1-smoothstep(fade_start,fade_end,t)) * color.a
;;   behind: src over shadow；front: shadow over src；only: 只留阴影。
;;
;; 性能
;;   * KEY：源 alpha / luminance 单通道平面，双线性采样只读 1 个通道；
;;   * 源 bbox + (u,t) 矩形求阴影 bbox，只填/模糊/合成 bbox 内像素；
;;   * 填充用逐行增量 t/u/sx/sy，避免逐像素重复点积；
;;   * RAD：填充时算好的半径，两遍模糊直接读取；
;;   * SH/TMP 在填充前整体清零，bbox 边缘读到的都是 0。
;;
;; 内存布局（packed）
;;   1024  manifest
;;   32768 arena: [params][pixels][SH][TMP][RAD][KEY]
;;   SH/TMP/RAD/KEY 各 W*H*4 字节；ec_alloc 预留 3×n。
(module
  (memory (export "memory") 2)
  (data (i32.const 1024) "__MANIFEST_BYTES__")
  (global $man_len i32 (i32.const __MANIFEST_LEN__))
  (global $ARENA i32 (i32.const 32768))
  (global $pages (mut i32) (i32.const 2))

  ;; ---- per render ----
  (global $W (mut i32) (i32.const 1))
  (global $H (mut i32) (i32.const 1))
  (global $PIX (mut i32) (i32.const 0))
  (global $SH (mut i32) (i32.const 0))
  (global $TMP (mut i32) (i32.const 0))
  (global $RAD (mut i32) (i32.const 0))
  (global $KEY (mut i32) (i32.const 0))
  (global $COL (mut i32) (i32.const 0))
  (global $TOTAL (mut i32) (i32.const 0))
  (global $FX0 (mut i32) (i32.const 0))
  (global $FX1 (mut i32) (i32.const -1))
  (global $FY0 (mut i32) (i32.const 0))
  (global $FY1 (mut i32) (i32.const -1))
  (global $MAXR (mut i32) (i32.const 0))
  (global $SRC_MODE (mut i32) (i32.const 0))
  (global $BEHIND (mut i32) (i32.const 1))
  (global $ONLY (mut i32) (i32.const 0))
  (global $FADEON (mut i32) (i32.const 1))
  (global $SMOOTH (mut i32) (i32.const 0))

  ;; ---- parameters ----
  (global $AX (mut f64) (f64.const 0))
  (global $AY (mut f64) (f64.const 0))
  (global $BX (mut f64) (f64.const 1))
  (global $BY (mut f64) (f64.const 0))
  (global $CX (mut f64) (f64.const 1))
  (global $CY (mut f64) (f64.const 1))
  (global $BLUR (mut f64) (f64.const 0))
  (global $BSTART (mut f64) (f64.const 0))
  (global $BEND (mut f64) (f64.const 1))
  (global $OPAC (mut f64) (f64.const 1))
  (global $FSTART (mut f64) (f64.const 0))
  (global $FEND (mut f64) (f64.const 1))
  (global $CR (mut f64) (f64.const 0))
  (global $CG (mut f64) (f64.const 0))
  (global $CB (mut f64) (f64.const 0))
  (global $CA (mut f64) (f64.const 1))
  (global $CRF (mut f32) (f32.const 0))
  (global $CGF (mut f32) (f32.const 0))
  (global $CBF (mut f32) (f32.const 0))
  (global $FADEK (mut f64) (f64.const 1))
  (global $COPAC (mut f64) (f64.const 1))

  ;; ---- geometry ----
  (global $LX (mut f64) (f64.const 1))
  (global $LY (mut f64) (f64.const 0))
  (global $NX (mut f64) (f64.const 0))
  (global $NY (mut f64) (f64.const 1))
  (global $WN (mut f64) (f64.const 1))
  (global $WU (mut f64) (f64.const 0))
  (global $INVWN (mut f64) (f64.const 1))
  (global $ANCHOR (mut f64) (f64.const 0))
  (global $SPAN (mut f64) (f64.const 1))
  (global $GROW (mut f64) (f64.const 0))
  (global $UMID (mut f64) (f64.const 0))
  (global $BENDON (mut i32) (i32.const 0))
  (global $P0X (mut f64) (f64.const 0))
  (global $P0Y (mut f64) (f64.const 0))
  (global $P1X (mut f64) (f64.const 0))
  (global $P1Y (mut f64) (f64.const 0))
  (global $P2X (mut f64) (f64.const 0))
  (global $P2Y (mut f64) (f64.const 0))
  (global $BKA (mut f64) (f64.const 0))
  (global $BKB (mut f64) (f64.const 0))
  (global $BKC (mut f64) (f64.const 0))
  ;; 直角弯折：两段折线的 N 坐标参数
  (global $SN0 (mut f64) (f64.const 0))
  (global $SNC (mut f64) (f64.const 0))
  (global $SN2 (mut f64) (f64.const 0))
  (global $SD0 (mut f64) (f64.const 0))
  (global $SD1 (mut f64) (f64.const 0))

  ;; ================= tiny helpers =================
  (func $imin (param $a i32) (param $b i32) (result i32)
    local.get $a local.get $b local.get $a local.get $b i32.lt_s select)
  (func $imax (param $a i32) (param $b i32) (result i32)
    local.get $a local.get $b local.get $a local.get $b i32.gt_s select)
  (func $clamp01 (param $x f64) (result f64)
    local.get $x f64.const 0 f64.max f64.const 1 f64.min)
  (func $smooth (param $x f64) (result f64)
    (local $u f64)
    local.get $x call $clamp01 local.set $u
    local.get $u local.get $u f64.mul
    f64.const 3 local.get $u f64.const 2 f64.mul f64.sub
    f64.mul)

  ;; 清零 n 字节（n 为 8 的倍数）
  (func $zeroMem (param $p i32) (param $n i32)
    (local $end i32)
    local.get $p local.get $n i32.add local.set $end
    (block $endB
      (loop $l
        local.get $p local.get $end i32.ge_u br_if $endB
        local.get $p i64.const 0 i64.store
        local.get $p i32.const 8 i32.add local.set $p
        br $l)))

  ;; 双线性采样 KEY 平面（单通道）
  (func $sampleKey (param $px f64) (param $py f64) (result f32)
    (local $x0 i32) (local $y0 i32) (local $x1 i32) (local $y1 i32)
    (local $fx f32) (local $fy f32)
    (local $a f32) (local $b f32) (local $c f32) (local $d f32)
    (local $top f32) (local $bot f32)
    local.get $px f64.const 0 f64.lt
    local.get $py f64.const 0 f64.lt i32.or
    local.get $px global.get $W f64.convert_i32_s f64.const 1 f64.sub f64.gt i32.or
    local.get $py global.get $H f64.convert_i32_s f64.const 1 f64.sub f64.gt i32.or
    (if (then f32.const 0 return))
    local.get $px i32.trunc_f64_s local.set $x0
    local.get $py i32.trunc_f64_s local.set $y0
    local.get $x0 i32.const 1 i32.add
    global.get $W i32.const 1 i32.sub call $imin local.set $x1
    local.get $y0 i32.const 1 i32.add
    global.get $H i32.const 1 i32.sub call $imin local.set $y1
    local.get $px local.get $x0 f64.convert_i32_s f64.sub f32.demote_f64 local.set $fx
    local.get $py local.get $y0 f64.convert_i32_s f64.sub f32.demote_f64 local.set $fy
    global.get $KEY
    local.get $y0 global.get $W i32.mul local.get $x0 i32.add i32.const 2 i32.shl i32.add
    f32.load local.set $a
    global.get $KEY
    local.get $y0 global.get $W i32.mul local.get $x1 i32.add i32.const 2 i32.shl i32.add
    f32.load local.set $b
    global.get $KEY
    local.get $y1 global.get $W i32.mul local.get $x0 i32.add i32.const 2 i32.shl i32.add
    f32.load local.set $c
    global.get $KEY
    local.get $y1 global.get $W i32.mul local.get $x1 i32.add i32.const 2 i32.shl i32.add
    f32.load local.set $d
    local.get $a local.get $b local.get $a f32.sub local.get $fx f32.mul f32.add local.set $top
    local.get $c local.get $d local.get $c f32.sub local.get $fx f32.mul f32.add local.set $bot
    local.get $top local.get $bot local.get $top f32.sub local.get $fy f32.mul f32.add)

  ;; 最近邻采样源 RGB（premultiplied 像素，除以采样 alpha 还原颜色）
  (func $sampleRGB (param $px f64) (param $py f64) (param $out i32) (param $a f32)
    (local $x i32) (local $y i32) (local $p i32) (local $inv f32)
    local.get $px f64.const 0 f64.lt
    local.get $py f64.const 0 f64.lt i32.or
    local.get $px global.get $W f64.convert_i32_s f64.const 1 f64.sub f64.gt i32.or
    local.get $py global.get $H f64.convert_i32_s f64.const 1 f64.sub f64.gt i32.or
    (if (then
      local.get $out f32.const 0 f32.store
      local.get $out f32.const 0 f32.store offset=4
      local.get $out f32.const 0 f32.store offset=8
      return))
    local.get $px i32.trunc_f64_s i32.const 0 call $imax
    global.get $W i32.const 1 i32.sub call $imin local.set $x
    local.get $py i32.trunc_f64_s i32.const 0 call $imax
    global.get $H i32.const 1 i32.sub call $imin local.set $y
    global.get $PIX
    local.get $y global.get $W i32.mul local.get $x i32.add i32.const 4 i32.shl i32.add
    local.set $p
    local.get $a f32.const 0.001 f32.gt
    (if (then
      f32.const 1 local.get $a f32.div local.set $inv
      local.get $out
      local.get $p f32.load local.get $inv f32.mul f32.store
      local.get $out
      local.get $p f32.load offset=4 local.get $inv f32.mul f32.store offset=4
      local.get $out
      local.get $p f32.load offset=8 local.get $inv f32.mul f32.store offset=8)
      (else
        local.get $out f32.const 0 f32.store
        local.get $out f32.const 0 f32.store offset=4
        local.get $out f32.const 0 f32.store offset=8)))

  ;; 不透明度渐隐：t 从 fade_start 到 fade_end，1 → 0
  (func $fadeT (param $t f64) (result f64)
    (local $den f64)
    global.get $FEND global.get $FSTART f64.sub local.set $den
    local.get $den f64.const 0.000001 f64.lt
    (if (result f64)
      (then
        local.get $t global.get $FEND f64.ge
        (if (result f64) (then f64.const 0) (else f64.const 1)))
      (else
        f64.const 1
        local.get $t global.get $FSTART f64.sub local.get $den f64.div
        call $smooth
        f64.sub)))

  ;; 渐进模糊半径（buffer px）
  (func $radT (param $t f64) (result i32)
    (local $den f64) (local $u f64)
    global.get $BEND global.get $BSTART f64.sub local.set $den
    local.get $den f64.const 0.000001 f64.lt
    (if (then
      local.get $t global.get $BEND f64.ge
      (if (result f64) (then f64.const 1) (else f64.const 0)) local.set $u)
      (else
        local.get $t global.get $BSTART f64.sub local.get $den f64.div
        call $clamp01 local.set $u))
    local.get $u call $smooth local.set $u
    local.get $u global.get $BLUR f64.mul
    f64.const 512 f64.min
    f64.const 0.5 f64.add
    i32.trunc_f64_s)

  ;; 二次弯折轴：解 (B(t)-Q)·N = 0，返回 t；无解/不在 [0,1] 返回 -1
  (func $bezT (param $qx f64) (param $qy f64) (result f64)
    (local $a f64) (local $b f64) (local $c f64)
    (local $disc f64) (local $sq f64) (local $r0 f64) (local $r1 f64)
    global.get $BKA local.set $a
    global.get $BKB local.set $b
    global.get $BKC
    local.get $qx global.get $NX f64.mul
    local.get $qy global.get $NY f64.mul f64.add f64.sub local.set $c
    local.get $a f64.abs f64.const 1e-9 f64.lt
    (if (then
      local.get $b f64.abs f64.const 1e-9 f64.lt
      (if (then f64.const -1 return))
      local.get $c f64.neg local.get $b f64.div local.set $r0
      local.get $r0 f64.const 0 f64.ge
      local.get $r0 f64.const 1 f64.le i32.and
      (if (then local.get $r0 return))
      f64.const -1 return))
    local.get $b local.get $b f64.mul
    f64.const 4 local.get $a f64.mul local.get $c f64.mul f64.sub local.set $disc
    local.get $disc f64.const 0 f64.lt (if (then f64.const -1 return))
    local.get $disc f64.sqrt local.set $sq
    local.get $b f64.neg local.get $sq f64.sub
    f64.const 2 local.get $a f64.mul f64.div local.set $r0
    local.get $b f64.neg local.get $sq f64.add
    f64.const 2 local.get $a f64.mul f64.div local.set $r1
    ;; 取较小的合法根
    local.get $r0 local.get $r1 f64.lt
    (if (then
      local.get $r0 f64.const 0 f64.ge local.get $r0 f64.const 1 f64.le i32.and
      (if (then local.get $r0 return))
      local.get $r1 f64.const 0 f64.ge local.get $r1 f64.const 1 f64.le i32.and
      (if (then local.get $r1 return)))
      (else
        local.get $r1 f64.const 0 f64.ge local.get $r1 f64.const 1 f64.le i32.and
        (if (then local.get $r1 return))
        local.get $r0 f64.const 0 f64.ge local.get $r0 f64.const 1 f64.le i32.and
        (if (then local.get $r0 return))))
    f64.const -1)

  ;; 直角弯折：两段折线 B(t)=P0→C（t≤0.5）、C→P2（t≥0.5）
  (func $sharpT (param $qx f64) (param $qy f64) (result f64)
    (local $qn f64) (local $t f64)
    local.get $qx global.get $NX f64.mul
    local.get $qy global.get $NY f64.mul f64.add local.set $qn
    global.get $SD0 f64.abs f64.const 1e-9 f64.gt
    (if (then
      local.get $qn global.get $SN0 f64.sub global.get $SD0 f64.div local.set $t
      local.get $t f64.const 0 f64.ge
      local.get $t f64.const 0.5 f64.le i32.and
      (if (then local.get $t return))))
    global.get $SD1 f64.abs f64.const 1e-9 f64.gt
    (if (then
      local.get $qn global.get $SNC f64.sub global.get $SD1 f64.div
      f64.const 0.5 f64.add local.set $t
      local.get $t f64.const 0.5 f64.ge
      local.get $t f64.const 1 f64.le i32.and
      (if (then local.get $t return))))
    f64.const -1)

  ;; 弯折 t：按平滑开关选择二次曲线或直角折线
  (func $bendT (param $qx f64) (param $qy f64) (result f64)
    global.get $SMOOTH
    (if (result f64)
      (then local.get $qx local.get $qy call $bezT)
      (else local.get $qx local.get $qy call $sharpT)))

  ;; 没有阴影时的收尾：only_shadow 要清空输出，其他模式原样返回
  (func $noShadow (result i32)
    global.get $ONLY
    (if (then
      global.get $PIX global.get $TOTAL call $zeroMem))
    i32.const 0)

  ;; ================= exports =================
  (func (export "ec_api_version") (result i32) i32.const 1)
  (func (export "ec_manifest_ptr") (result i32) i32.const 1024)
  (func (export "ec_manifest_len") (result i32) global.get $man_len)

  (func (export "ec_alloc") (param $n i32) (result i32)
    (local $need i32) (local $want i32)
    ;; params + pixels + SH/TMP/RAD/KEY（各 4*W*H）都在 3×n 内
    local.get $n i32.const 3 i32.mul
    global.get $ARENA i32.add i32.const 65536 i32.add local.set $need
    local.get $need
    global.get $pages i32.const 16 i32.shl i32.gt_u
    (if (then
      local.get $need i32.const 65535 i32.add i32.const 16 i32.shr_u local.set $want
      local.get $want global.get $pages i32.sub memory.grow drop
      local.get $want global.set $pages))
    global.get $ARENA)

  ;; ================= horizontal variable box blur =================
  ;; SH -> TMP，只处理 FX0..FX1 / FY0..FY1
  (func $blurH
    (local $y i32) (local $x i32)
    (local $srow i32) (local $trow i32) (local $rbase i32)
    (local $r i32) (local $tl i32) (local $tr i32)
    (local $left i32) (local $right i32)
    (local $sum f32)
    global.get $FY0 local.set $y
    (block $yend
      (loop $yl
        local.get $y global.get $FY1 i32.gt_s br_if $yend
        global.get $SH
        local.get $y global.get $W i32.mul i32.const 2 i32.shl i32.add
        local.set $srow
        global.get $TMP
        local.get $y global.get $W i32.mul i32.const 2 i32.shl i32.add
        local.set $trow
        global.get $RAD
        local.get $y global.get $W i32.mul global.get $FX0 i32.add i32.const 2 i32.shl i32.add
        local.set $rbase
        local.get $rbase i32.load local.set $r
        global.get $FX0 local.get $r i32.sub i32.const 0 call $imax local.set $left
        global.get $FX0 local.get $r i32.add
        global.get $W i32.const 1 i32.sub call $imin local.set $right
        f32.const 0 local.set $sum
        local.get $left local.set $x
        (block $iend
          (loop $il
            local.get $x local.get $right i32.gt_s br_if $iend
            local.get $sum
            local.get $srow local.get $x i32.const 2 i32.shl i32.add f32.load
            f32.add local.set $sum
            local.get $x i32.const 1 i32.add local.set $x
            br $il))
        global.get $FX0 local.set $x
        (block $xend
          (loop $xl
            local.get $x global.get $FX1 i32.gt_s br_if $xend
            local.get $x global.get $FX0 i32.gt_s
            (if (then
              local.get $rbase
              local.get $x global.get $FX0 i32.sub i32.const 2 i32.shl i32.add
              i32.load local.set $r
              local.get $x local.get $r i32.sub i32.const 0 call $imax local.set $tl
              local.get $x local.get $r i32.add
              global.get $W i32.const 1 i32.sub call $imin local.set $tr
              ;; left -> tl
              (block $lend
                (loop $ll
                  local.get $left local.get $tl i32.ge_s br_if $lend
                  local.get $sum
                  local.get $srow local.get $left i32.const 2 i32.shl i32.add f32.load
                  f32.sub local.set $sum
                  local.get $left i32.const 1 i32.add local.set $left
                  br $ll))
              (block $lend2
                (loop $ll2
                  local.get $left local.get $tl i32.le_s br_if $lend2
                  local.get $left i32.const 1 i32.sub local.set $left
                  local.get $sum
                  local.get $srow local.get $left i32.const 2 i32.shl i32.add f32.load
                  f32.add local.set $sum
                  br $ll2))
              ;; right -> tr
              (block $rend
                (loop $rl
                  local.get $right local.get $tr i32.ge_s br_if $rend
                  local.get $right i32.const 1 i32.add local.set $right
                  local.get $sum
                  local.get $srow local.get $right i32.const 2 i32.shl i32.add f32.load
                  f32.add local.set $sum
                  br $rl))
              (block $rend2
                (loop $rl2
                  local.get $right local.get $tr i32.le_s br_if $rend2
                  local.get $sum
                  local.get $srow local.get $right i32.const 2 i32.shl i32.add f32.load
                  f32.sub local.set $sum
                  local.get $right i32.const 1 i32.sub local.set $right
                  br $rl2))))
            local.get $trow local.get $x i32.const 2 i32.shl i32.add
            local.get $sum f32.const 0 f32.max
            local.get $right local.get $left i32.sub i32.const 1 i32.add
            f32.convert_i32_s
            f32.div
            f32.store
            local.get $x i32.const 1 i32.add local.set $x
            br $xl))
        local.get $y i32.const 1 i32.add local.set $y
        br $yl)))

  ;; ================= vertical variable box blur =================
  ;; TMP -> SH，只处理 FX0..FX1 / FY0..FY1
  (func $blurV
    (local $x i32) (local $y i32)
    (local $sbase i32) (local $tbase i32) (local $rbase i32)
    (local $r i32) (local $tt i32) (local $tb i32)
    (local $top i32) (local $bot i32)
    (local $sum f32)
    global.get $FX0 local.set $x
    (block $xend
      (loop $xl
        local.get $x global.get $FX1 i32.gt_s br_if $xend
        global.get $SH local.get $x i32.const 2 i32.shl i32.add local.set $sbase
        global.get $TMP local.get $x i32.const 2 i32.shl i32.add local.set $tbase
        global.get $RAD
        global.get $FY0 global.get $W i32.mul local.get $x i32.add i32.const 2 i32.shl i32.add
        local.set $rbase
        local.get $rbase i32.load local.set $r
        global.get $FY0 local.get $r i32.sub i32.const 0 call $imax local.set $top
        global.get $FY0 local.get $r i32.add
        global.get $H i32.const 1 i32.sub call $imin local.set $bot
        f32.const 0 local.set $sum
        local.get $top local.set $y
        (block $iend
          (loop $il
            local.get $y local.get $bot i32.gt_s br_if $iend
            local.get $sum
            local.get $tbase
            local.get $y global.get $W i32.mul i32.const 2 i32.shl i32.add
            f32.load f32.add local.set $sum
            local.get $y i32.const 1 i32.add local.set $y
            br $il))
        global.get $FY0 local.set $y
        (block $yend
          (loop $yl
            local.get $y global.get $FY1 i32.gt_s br_if $yend
            local.get $y global.get $FY0 i32.gt_s
            (if (then
              local.get $rbase
              local.get $y global.get $FY0 i32.sub
              global.get $W i32.mul i32.const 2 i32.shl i32.add
              i32.load local.set $r
              local.get $y local.get $r i32.sub i32.const 0 call $imax local.set $tt
              local.get $y local.get $r i32.add
              global.get $H i32.const 1 i32.sub call $imin local.set $tb
              ;; top -> tt
              (block $lend
                (loop $ll
                  local.get $top local.get $tt i32.ge_s br_if $lend
                  local.get $sum
                  local.get $tbase
                  local.get $top global.get $W i32.mul i32.const 2 i32.shl i32.add
                  f32.load f32.sub local.set $sum
                  local.get $top i32.const 1 i32.add local.set $top
                  br $ll))
              (block $lend2
                (loop $ll2
                  local.get $top local.get $tt i32.le_s br_if $lend2
                  local.get $top i32.const 1 i32.sub local.set $top
                  local.get $sum
                  local.get $tbase
                  local.get $top global.get $W i32.mul i32.const 2 i32.shl i32.add
                  f32.load f32.add local.set $sum
                  br $ll2))
              ;; bottom -> tb
              (block $rend
                (loop $rl
                  local.get $bot local.get $tb i32.ge_s br_if $rend
                  local.get $bot i32.const 1 i32.add local.set $bot
                  local.get $sum
                  local.get $tbase
                  local.get $bot global.get $W i32.mul i32.const 2 i32.shl i32.add
                  f32.load f32.add local.set $sum
                  br $rl))
              (block $rend2
                (loop $rl2
                  local.get $bot local.get $tb i32.le_s br_if $rend2
                  local.get $sum
                  local.get $tbase
                  local.get $bot global.get $W i32.mul i32.const 2 i32.shl i32.add
                  f32.load f32.sub local.set $sum
                  local.get $bot i32.const 1 i32.sub local.set $bot
                  br $rl2))))
            local.get $sbase
            local.get $y global.get $W i32.mul i32.const 2 i32.shl i32.add
            local.get $sum f32.const 0 f32.max
            local.get $bot local.get $top i32.sub i32.const 1 i32.add
            f32.convert_i32_s
            f32.div
            f32.store
            local.get $y i32.const 1 i32.add local.set $y
            br $yl))
        local.get $x i32.const 1 i32.add local.set $x
        br $xl)))

  ;; ================= render =================
  (func (export "ec_render")
    (param $pixels i32) (param $w i32) (param $h i32)
    (param $params i32) (param $nparams i32)
    (param $time f64) (param $scale f64) (result i32)
    (local $i i32) (local $x i32) (local $y i32)
    (local $p i32) (local $q i32) (local $cp i32) (local $idx i32) (local $plane i32)
    (local $dx f64) (local $dy f64) (local $len f64)
    (local $mx f64) (local $my f64)
    (local $wx f64) (local $wy f64) (local $wn f64)
    (local $hmin f64) (local $hmax f64) (local $hh f64)
    (local $anchor f64) (local $far f64) (local $span f64)
    (local $t0 f64) (local $dt f64) (local $t f64)
    (local $dh f64) (local $du f64) (local $dsx f64) (local $dsy f64)
    (local $u f64) (local $sx f64) (local $sy f64)
    (local $s f64) (local $ds f64) (local $usrc f64)
    (local $av f32) (local $sa f32) (local $sr f32) (local $sg f32)
    (local $sb f32) (local $saa f32) (local $inv f32)
    (local $or f32) (local $og f32) (local $ob f32) (local $oa f32)
    (local $cr f32) (local $cg f32) (local $cb f32)
    (local $fade f32)
    (local $kx0 i32) (local $kx1 i32) (local $ky0 i32) (local $ky1 i32)
    (local $fx0 i32) (local $fx1 i32) (local $fy0 i32) (local $fy1 i32)
    (local $umin f64) (local $umax f64) (local $uu f64)
    (local $bbx0 f64) (local $bbx1 f64) (local $bby0 f64) (local $bby1 f64)
    (local $qx f64) (local $qy f64)
    (local $bx f64) (local $by f64) (local $omt f64)
    (local $b0 f64) (local $b1 f64) (local $b2 f64)
    (local $uout f64) (local $half f64) (local $smax f64)
    (local $hx f64) (local $hy f64)
    (local $minx f64) (local $maxx f64) (local $miny f64) (local $maxy f64)

    local.get $w i32.const 0 i32.le_s
    local.get $h i32.const 0 i32.le_s i32.or
    local.get $nparams i32.const 27 i32.lt_s i32.or
    (if (then i32.const 1 return))

    ;; ---- parameters（声明顺序，27 个扁平 f64）----
    ;; 0 ax | 1 ay | 2 bx | 3 by | 4 cx | 5 cy
    ;; 6 blur_on | 7 blur | 8 blur_start | 9 blur_end
    ;; 10 fade_on | 11 opacity | 12 fade_start | 13 fade_end
    ;; 14 r | 15 g | 16 b | 17 a | 18 color_opacity
    ;; 19 source | 20 behind | 21 only | 22 expand
    ;; 23 bend | 24 smooth | 25 bend_x | 26 bend_y
    local.get $params f64.load local.set $dx          ;; ax 临时复用
    local.get $params f64.load offset=8 local.set $dy ;; ay
    local.get $dx global.set $AX
    local.get $dy global.set $AY
    local.get $params f64.load offset=16 f64.const 0 f64.max local.set $wx
    local.get $params f64.load offset=24 f64.const 0 f64.max local.set $wy
    local.get $wx global.set $BX
    local.get $wy global.set $BY
    local.get $params f64.load offset=32 local.set $mx
    local.get $params f64.load offset=40 local.set $my
    local.get $mx global.set $CX
    local.get $my global.set $CY

    ;; 模糊开关：关闭时直接把半径置 0，后续模糊 pass 自动跳过
    local.get $params f64.load offset=48 f64.const 0.5 f64.gt
    (if (then
      local.get $params f64.load offset=56 f64.const 0 f64.max
      local.get $scale f64.mul f64.const 512 f64.min global.set $BLUR)
      (else f64.const 0 global.set $BLUR))
    local.get $params f64.load offset=64 f64.const 100 f64.div
    f64.const 0 f64.max f64.const 1 f64.min global.set $BSTART
    local.get $params f64.load offset=72 f64.const 100 f64.div
    f64.const 0 f64.max f64.const 1 f64.min global.set $BEND

    ;; 淡出开关
    local.get $params f64.load offset=80 f64.const 0.5 f64.gt global.set $FADEON
    local.get $params f64.load offset=88 f64.const 100 f64.div
    f64.const 0 f64.max f64.const 1 f64.min global.set $OPAC
    local.get $params f64.load offset=96 f64.const 100 f64.div
    f64.const 0 f64.max f64.const 1 f64.min global.set $FSTART
    local.get $params f64.load offset=104 f64.const 100 f64.div
    f64.const 0 f64.max f64.const 1 f64.min global.set $FEND
    local.get $params f64.load offset=112 f64.const 0 f64.max f64.const 1 f64.min global.set $CR
    local.get $params f64.load offset=120 f64.const 0 f64.max f64.const 1 f64.min global.set $CG
    local.get $params f64.load offset=128 f64.const 0 f64.max f64.const 1 f64.min global.set $CB
    local.get $params f64.load offset=136 f64.const 0 f64.max f64.const 1 f64.min global.set $CA
    local.get $params f64.load offset=144 f64.const 100 f64.div
    f64.const 0 f64.max f64.const 1 f64.min global.set $COPAC
    local.get $params f64.load offset=152 f64.const 0.5 f64.add
    i32.trunc_f64_s global.set $SRC_MODE
    local.get $params f64.load offset=160 f64.const 0.5 f64.gt global.set $BEHIND
    local.get $params f64.load offset=168 f64.const 0.5 f64.gt global.set $ONLY
    local.get $params f64.load offset=176 f64.const 100 f64.div
    f64.const -0.95 f64.max f64.const 3 f64.min global.set $GROW
    local.get $params f64.load offset=184 f64.const 0.5 f64.gt global.set $BENDON
    local.get $params f64.load offset=192 f64.const 0.5 f64.gt global.set $SMOOTH
    local.get $params f64.load offset=200 global.set $P2X
    local.get $params f64.load offset=208 global.set $P2Y

    global.get $CR f32.demote_f64 global.set $CRF
    global.get $CG f32.demote_f64 global.set $CGF
    global.get $CB f32.demote_f64 global.set $CBF
    global.get $OPAC global.get $CA f64.mul
    global.get $COPAC f64.mul global.set $FADEK
    global.get $BLUR f64.const 0.5 f64.add i32.trunc_f64_s global.set $MAXR

    ;; ---- frame state / packed buffers ----
    local.get $w global.set $W
    local.get $h global.set $H
    local.get $pixels global.set $PIX
    local.get $w local.get $h i32.mul i32.const 16 i32.mul local.set $idx
    local.get $idx global.set $TOTAL
    local.get $idx i32.const 2 i32.shr_u local.set $plane
    local.get $pixels local.get $idx i32.add global.set $SH
    global.get $SH local.get $plane i32.add global.set $TMP
    global.get $TMP local.get $plane i32.add global.set $RAD
    global.get $RAD local.get $plane i32.add global.set $KEY
    global.get $KEY local.get $plane i32.add global.set $COL

    ;; ---- geometry ----
    global.get $BX global.get $AX f64.sub local.set $dx
    global.get $BY global.get $AY f64.sub local.set $dy
    local.get $dx local.get $dx f64.mul
    local.get $dy local.get $dy f64.mul f64.add f64.sqrt local.set $len
    local.get $len f64.const 0.0001 f64.lt
    (if (then call $noShadow return))
    local.get $dx local.get $len f64.div global.set $LX
    local.get $dy local.get $len f64.div global.set $LY
    global.get $AX global.get $BX f64.add f64.const 0.5 f64.mul local.set $mx
    global.get $AY global.get $BY f64.add f64.const 0.5 f64.mul local.set $my
    global.get $CX local.get $mx f64.sub local.set $wx
    global.get $CY local.get $my f64.sub local.set $wy
    ;; N = (-ly, lx)，翻到 W 那一侧
    local.get $wx global.get $LY f64.neg f64.mul
    local.get $wy global.get $LX f64.mul f64.add local.set $wn
    local.get $wn f64.const 0 f64.lt
    (if (then
      global.get $LY global.set $NX
      global.get $LX f64.neg global.set $NY
      local.get $wn f64.neg local.set $wn)
      (else
        global.get $LY f64.neg global.set $NX
        global.get $LX global.set $NY))
    local.get $wn f64.const 0.0001 f64.lt
    (if (then call $noShadow return))
    local.get $wn global.set $WN
    f64.const 1 local.get $wn f64.div global.set $INVWN
    local.get $wx global.get $LX f64.mul
    local.get $wy global.get $LY f64.mul f64.add global.set $WU

    ;; ---- KEY 平面：源 alpha/luminance + h 范围 + 源 bbox ----
    f64.const 1e30 local.set $hmin
    f64.const -1e30 local.set $hmax
    global.get $W local.set $kx0
    i32.const -1 local.set $kx1
    global.get $H local.set $ky0
    i32.const -1 local.set $ky1
    i32.const 0 local.set $y
    (block $yend
      (loop $yl
        local.get $y global.get $H i32.ge_s br_if $yend
        i32.const 0 local.set $x
        (block $xend
          (loop $xl
            local.get $x global.get $W i32.ge_s br_if $xend
            global.get $PIX
            local.get $y global.get $W i32.mul local.get $x i32.add
            i32.const 16 i32.mul i32.add local.set $p
            global.get $SRC_MODE
            (if (result f32)
              (then
                local.get $p f32.load f32.const 0.2126 f32.mul
                local.get $p f32.load offset=4 f32.const 0.7152 f32.mul f32.add
                local.get $p f32.load offset=8 f32.const 0.0722 f32.mul f32.add)
              (else local.get $p f32.load offset=12))
            local.set $av
            global.get $KEY
            local.get $y global.get $W i32.mul local.get $x i32.add
            i32.const 2 i32.shl i32.add
            local.get $av f32.store
            local.get $av f32.const 0.004 f32.gt
            (if (then
              local.get $x local.get $kx0 i32.lt_s
              (if (then local.get $x local.set $kx0))
              local.get $x local.get $kx1 i32.gt_s
              (if (then local.get $x local.set $kx1))
              local.get $y local.get $ky0 i32.lt_s
              (if (then local.get $y local.set $ky0))
              local.get $y local.get $ky1 i32.gt_s
              (if (then local.get $y local.set $ky1))
              local.get $x f64.convert_i32_s global.get $AX f64.sub
              global.get $NX f64.mul
              local.get $y f64.convert_i32_s global.get $AY f64.sub
              global.get $NY f64.mul f64.add local.set $hh
              local.get $hh local.get $hmin f64.lt
              (if (then local.get $hh local.set $hmin))
              local.get $hh local.get $hmax f64.gt
              (if (then local.get $hh local.set $hmax))))
            local.get $x i32.const 1 i32.add local.set $x
            br $xl))
        local.get $y i32.const 1 i32.add local.set $y
        br $yl))
    local.get $kx1 i32.const 0 i32.lt_s
    (if (then call $noShadow return))

    ;; ---- 源高度 → 阴影 t 的锚点 ----
    local.get $hmin f64.abs local.get $hmax f64.abs f64.lt
    (if (then
      local.get $hmin local.set $anchor
      local.get $hmax local.set $far)
      (else
        local.get $hmax local.set $anchor
        local.get $hmin local.set $far))
    local.get $far local.get $anchor f64.sub local.set $span
    local.get $span f64.abs f64.const 0.75 f64.lt
    (if (then call $noShadow return))
    local.get $anchor global.set $ANCHOR
    local.get $span global.set $SPAN

    ;; ---- 阴影 bbox：源 bbox 的 u 范围 × t∈[0,1] ----
    ;; u=(x-ax)*lx+(y-ay)*ly 是线性的，四角求 min/max
    local.get $kx0 f64.convert_i32_s global.get $AX f64.sub global.get $LX f64.mul
    local.get $ky0 f64.convert_i32_s global.get $AY f64.sub global.get $LY f64.mul
    f64.add local.set $umin
    local.get $umin local.set $umax
    local.get $kx1 f64.convert_i32_s global.get $AX f64.sub global.get $LX f64.mul
    local.get $ky0 f64.convert_i32_s global.get $AY f64.sub global.get $LY f64.mul
    f64.add local.set $uu
    local.get $uu local.get $umin f64.lt (if (then local.get $uu local.set $umin))
    local.get $uu local.get $umax f64.gt (if (then local.get $uu local.set $umax))
    local.get $kx0 f64.convert_i32_s global.get $AX f64.sub global.get $LX f64.mul
    local.get $ky1 f64.convert_i32_s global.get $AY f64.sub global.get $LY f64.mul
    f64.add local.set $uu
    local.get $uu local.get $umin f64.lt (if (then local.get $uu local.set $umin))
    local.get $uu local.get $umax f64.gt (if (then local.get $uu local.set $umax))
    local.get $kx1 f64.convert_i32_s global.get $AX f64.sub global.get $LX f64.mul
    local.get $ky1 f64.convert_i32_s global.get $AY f64.sub global.get $LY f64.mul
    f64.add local.set $uu
    local.get $uu local.get $umin f64.lt (if (then local.get $uu local.set $umin))
    local.get $uu local.get $umax f64.gt (if (then local.get $uu local.set $umax))

    ;; 源切向范围的中心：远端放大绕这条中心线张开
    local.get $umin local.get $umax f64.add f64.const 0.5 f64.mul global.set $UMID

    ;; ---- 二次弯折：B(0)=P0（基线中点），B(0.5)=C（方向点），B(1)=P2（弯折点）----
    global.get $BENDON
    (if (then
      global.get $AX global.get $UMID global.get $LX f64.mul f64.add global.set $P0X
      global.get $AY global.get $UMID global.get $LY f64.mul f64.add global.set $P0Y
      ;; P1 = 2*C - 0.5*(P0+P2)，使 B(0.5)=C
      f64.const 2 global.get $CX f64.mul
      f64.const 0.5 global.get $P0X global.get $P2X f64.add f64.mul f64.sub
      global.set $P1X
      f64.const 2 global.get $CY f64.mul
      f64.const 0.5 global.get $P0Y global.get $P2Y f64.add f64.mul f64.sub
      global.set $P1Y
      ;; B(t)=P0 + 2t(P1-P0) + t^2(P0-2P1+P2)
      global.get $P0X f64.const 2 global.get $P1X f64.mul f64.sub global.get $P2X f64.add
      global.get $NX f64.mul
      global.get $P0Y f64.const 2 global.get $P1Y f64.mul f64.sub global.get $P2Y f64.add
      global.get $NY f64.mul f64.add global.set $BKA
      global.get $P1X global.get $P0X f64.sub global.get $NX f64.mul
      global.get $P1Y global.get $P0Y f64.sub global.get $NY f64.mul f64.add
      f64.const 2 f64.mul global.set $BKB
      global.get $P0X global.get $NX f64.mul
      global.get $P0Y global.get $NY f64.mul f64.add global.set $BKC
      ;; 直角折线的 N 坐标参数：段 0 P0→C，段 1 C→P2
      global.get $P0X global.get $NX f64.mul
      global.get $P0Y global.get $NY f64.mul f64.add global.set $SN0
      global.get $CX global.get $NX f64.mul
      global.get $CY global.get $NY f64.mul f64.add global.set $SNC
      global.get $P2X global.get $NX f64.mul
      global.get $P2Y global.get $NY f64.mul f64.add global.set $SN2
      global.get $SNC global.get $SN0 f64.sub f64.const 2 f64.mul global.set $SD0
      global.get $SN2 global.get $SNC f64.sub f64.const 2 f64.mul global.set $SD1))

    f64.const 1e30 local.set $bbx0
    f64.const -1e30 local.set $bbx1
    f64.const 1e30 local.set $bby0
    f64.const -1e30 local.set $bby1
    ;; t=0, u=umin
    global.get $AX local.get $umin global.get $LX f64.mul f64.add local.set $qx
    global.get $AY local.get $umin global.get $LY f64.mul f64.add local.set $qy
    local.get $qx local.get $bbx0 f64.lt (if (then local.get $qx local.set $bbx0))
    local.get $qx local.get $bbx1 f64.gt (if (then local.get $qx local.set $bbx1))
    local.get $qy local.get $bby0 f64.lt (if (then local.get $qy local.set $bby0))
    local.get $qy local.get $bby1 f64.gt (if (then local.get $qy local.set $bby1))
    ;; t=0, u=umax
    global.get $AX local.get $umax global.get $LX f64.mul f64.add local.set $qx
    global.get $AY local.get $umax global.get $LY f64.mul f64.add local.set $qy
    local.get $qx local.get $bbx0 f64.lt (if (then local.get $qx local.set $bbx0))
    local.get $qx local.get $bbx1 f64.gt (if (then local.get $qx local.set $bbx1))
    local.get $qy local.get $bby0 f64.lt (if (then local.get $qy local.set $bby0))
    local.get $qy local.get $bby1 f64.gt (if (then local.get $qy local.set $bby1))
    ;; t=1 的切向范围绕 UMID 缩放 s=1+expand
    f64.const 1 global.get $GROW f64.add local.set $s
    ;; t=1, u=umin
    global.get $AX
    global.get $UMID
    local.get $umin global.get $UMID f64.sub local.get $s f64.mul f64.add
    global.get $WU f64.add global.get $LX f64.mul f64.add
    global.get $WN global.get $NX f64.mul f64.add local.set $qx
    global.get $AY
    global.get $UMID
    local.get $umin global.get $UMID f64.sub local.get $s f64.mul f64.add
    global.get $WU f64.add global.get $LY f64.mul f64.add
    global.get $WN global.get $NY f64.mul f64.add local.set $qy
    local.get $qx local.get $bbx0 f64.lt (if (then local.get $qx local.set $bbx0))
    local.get $qx local.get $bbx1 f64.gt (if (then local.get $qx local.set $bbx1))
    local.get $qy local.get $bby0 f64.lt (if (then local.get $qy local.set $bby0))
    local.get $qy local.get $bby1 f64.gt (if (then local.get $qy local.set $bby1))
    ;; t=1, u=umax
    global.get $AX
    global.get $UMID
    local.get $umax global.get $UMID f64.sub local.get $s f64.mul f64.add
    global.get $WU f64.add global.get $LX f64.mul f64.add
    global.get $WN global.get $NX f64.mul f64.add local.set $qx
    global.get $AY
    global.get $UMID
    local.get $umax global.get $UMID f64.sub local.get $s f64.mul f64.add
    global.get $WU f64.add global.get $LY f64.mul f64.add
    global.get $WN global.get $NY f64.mul f64.add local.set $qy
    local.get $qx local.get $bbx0 f64.lt (if (then local.get $qx local.set $bbx0))
    local.get $qx local.get $bbx1 f64.gt (if (then local.get $qx local.set $bbx1))
    local.get $qy local.get $bby0 f64.lt (if (then local.get $qy local.set $bby0))
    local.get $qy local.get $bby1 f64.gt (if (then local.get $qy local.set $bby1))

    ;; ---- 弯折时把凸包 P0/P1/P2 与横向半宽并入 bbox ----
    global.get $BENDON
    (if (then
      local.get $umin global.get $UMID f64.sub f64.abs
      local.get $umax global.get $UMID f64.sub f64.abs f64.max local.set $half
      f64.const 1 global.get $GROW f64.add f64.const 1 f64.max local.set $smax
      local.get $half local.get $smax f64.mul local.set $half
      local.get $half global.get $LX f64.abs f64.mul local.set $hx
      local.get $half global.get $LY f64.abs f64.mul local.set $hy
      global.get $P0X global.get $P1X f64.min global.get $P2X f64.min local.set $minx
      global.get $P0X global.get $P1X f64.max global.get $P2X f64.max local.set $maxx
      global.get $P0Y global.get $P1Y f64.min global.get $P2Y f64.min local.set $miny
      global.get $P0Y global.get $P1Y f64.max global.get $P2Y f64.max local.set $maxy
      local.get $minx local.get $hx f64.sub local.get $bbx0 f64.min local.set $bbx0
      local.get $maxx local.get $hx f64.add local.get $bbx1 f64.max local.set $bbx1
      local.get $miny local.get $hy f64.sub local.get $bby0 f64.min local.set $bby0
      local.get $maxy local.get $hy f64.add local.get $bby1 f64.max local.set $bby1))

    local.get $bbx0 global.get $MAXR f64.convert_i32_s f64.sub
    f64.floor i32.trunc_f64_s i32.const 0 call $imax local.set $fx0
    local.get $bbx1 global.get $MAXR f64.convert_i32_s f64.add
    f64.ceil i32.trunc_f64_s global.get $W i32.const 1 i32.sub call $imin local.set $fx1
    local.get $bby0 global.get $MAXR f64.convert_i32_s f64.sub
    f64.floor i32.trunc_f64_s i32.const 0 call $imax local.set $fy0
    local.get $bby1 global.get $MAXR f64.convert_i32_s f64.add
    f64.ceil i32.trunc_f64_s global.get $H i32.const 1 i32.sub call $imin local.set $fy1
    local.get $fx0 local.get $fx1 i32.gt_s
    local.get $fy0 local.get $fy1 i32.gt_s i32.or
    (if (then call $noShadow return))
    local.get $fx0 global.set $FX0
    local.get $fx1 global.set $FX1
    local.get $fy0 global.set $FY0
    local.get $fy1 global.set $FY1

    ;; ---- 清空 SH/TMP（bbox 外读到的都是 0）----
    global.get $SH local.get $plane i32.const 2 i32.mul call $zeroMem

    ;; ---- 逆映射填阴影 alpha + 半径 ----
    local.get $fy0 local.set $y
    (block $fyend
      (loop $fyl
        local.get $y local.get $fy1 i32.gt_s br_if $fyend
        ;; t at x=fx0 ; dt = nx/wn
        local.get $fx0 f64.convert_i32_s global.get $AX f64.sub
        global.get $NX f64.mul
        local.get $y f64.convert_i32_s global.get $AY f64.sub
        global.get $NY f64.mul f64.add global.get $INVWN f64.mul local.set $t0
        global.get $NX global.get $INVWN f64.mul local.set $dt
        local.get $t0 local.set $t
        ;; h = anchor + t*span
        global.get $ANCHOR local.get $t global.get $SPAN f64.mul f64.add local.set $hh
        ;; u = (x-ax)*lx + (y-ay)*ly - t*wu
        local.get $fx0 f64.convert_i32_s global.get $AX f64.sub
        global.get $LX f64.mul
        local.get $y f64.convert_i32_s global.get $AY f64.sub
        global.get $LY f64.mul f64.add
        local.get $t global.get $WU f64.mul f64.sub local.set $u
        ;; s = 1 + expand*t ; usrc = umid + (u-umid)/s
        f64.const 1 global.get $GROW local.get $t f64.mul f64.add local.set $s
        global.get $UMID
        local.get $u global.get $UMID f64.sub local.get $s f64.div f64.add local.set $usrc
        ;; sx/sy = A + usrc*L + h*N
        global.get $AX local.get $usrc global.get $LX f64.mul f64.add
        local.get $hh global.get $NX f64.mul f64.add local.set $sx
        global.get $AY local.get $usrc global.get $LY f64.mul f64.add
        local.get $hh global.get $NY f64.mul f64.add local.set $sy
        ;; 增量
        local.get $dt global.get $SPAN f64.mul local.set $dh
        global.get $LX local.get $dt global.get $WU f64.mul f64.sub local.set $du
        global.get $GROW local.get $dt f64.mul local.set $ds
        local.get $du global.get $LX f64.mul
        local.get $dh global.get $NX f64.mul f64.add local.set $dsx
        local.get $du global.get $LY f64.mul
        local.get $dh global.get $NY f64.mul f64.add local.set $dsy
        ;; 指针
        global.get $SH
        local.get $y global.get $W i32.mul local.get $fx0 i32.add i32.const 2 i32.shl i32.add
        local.set $p
        global.get $RAD
        local.get $y global.get $W i32.mul local.get $fx0 i32.add i32.const 2 i32.shl i32.add
        local.set $q
        global.get $COL
        local.get $y global.get $W i32.mul local.get $fx0 i32.add i32.const 12 i32.mul i32.add
        local.set $cp
        local.get $fx0 local.set $x
        (block $fxend
          (loop $fxl
            local.get $x local.get $fx1 i32.gt_s br_if $fxend
            local.get $p f32.const 0 f32.store
            local.get $q i32.const 0 i32.store
            global.get $BENDON
            (if (then
              ;; 弯折：逐像素解 t，B(t)，再 u/usrc/sx/sy
              local.get $x f64.convert_i32_s
              local.get $y f64.convert_i32_s
              call $bendT local.set $t
              local.get $t f64.const 0 f64.ge
              (if (then
                global.get $SMOOTH
                (if (then
                  f64.const 1 local.get $t f64.sub local.set $omt
                  local.get $omt local.get $omt f64.mul local.set $b0
                  f64.const 2 local.get $omt f64.mul local.get $t f64.mul local.set $b1
                  local.get $t local.get $t f64.mul local.set $b2
                  global.get $P0X local.get $b0 f64.mul
                  global.get $P1X local.get $b1 f64.mul f64.add
                  global.get $P2X local.get $b2 f64.mul f64.add local.set $bx
                  global.get $P0Y local.get $b0 f64.mul
                  global.get $P1Y local.get $b1 f64.mul f64.add
                  global.get $P2Y local.get $b2 f64.mul f64.add local.set $by)
                  (else
                    local.get $t f64.const 0.5 f64.le
                    (if (then
                      local.get $t f64.const 2 f64.mul local.set $b1
                      global.get $P0X
                      global.get $CX global.get $P0X f64.sub
                      local.get $b1 f64.mul f64.add local.set $bx
                      global.get $P0Y
                      global.get $CY global.get $P0Y f64.sub
                      local.get $b1 f64.mul f64.add local.set $by)
                      (else
                        local.get $t f64.const 0.5 f64.sub
                        f64.const 2 f64.mul local.set $b1
                        global.get $CX
                        global.get $P2X global.get $CX f64.sub
                        local.get $b1 f64.mul f64.add local.set $bx
                        global.get $CY
                        global.get $P2Y global.get $CY f64.sub
                        local.get $b1 f64.mul f64.add local.set $by))))
                local.get $x f64.convert_i32_s local.get $bx f64.sub global.get $LX f64.mul
                local.get $y f64.convert_i32_s local.get $by f64.sub global.get $LY f64.mul
                f64.add local.set $uout
                f64.const 1 global.get $GROW local.get $t f64.mul f64.add local.set $s
                global.get $UMID local.get $uout local.get $s f64.div f64.add local.set $usrc
                global.get $ANCHOR local.get $t global.get $SPAN f64.mul f64.add local.set $hh
                global.get $AX local.get $usrc global.get $LX f64.mul f64.add
                local.get $hh global.get $NX f64.mul f64.add local.set $sx
                global.get $AY local.get $usrc global.get $LY f64.mul f64.add
                local.get $hh global.get $NY f64.mul f64.add local.set $sy
                local.get $sx local.get $sy call $sampleKey local.set $av
                local.get $p local.get $av f32.store
                global.get $SRC_MODE i32.const 2 i32.eq
                (if (then
                  local.get $sx local.get $sy local.get $cp local.get $av call $sampleRGB))
                local.get $q local.get $t call $radT i32.store)))
              (else
                local.get $t f64.const 0 f64.ge
                local.get $t f64.const 1 f64.le i32.and
                (if (then
                  local.get $sx local.get $sy call $sampleKey local.set $av
                  local.get $p local.get $av f32.store
                  global.get $SRC_MODE i32.const 2 i32.eq
                  (if (then
                    local.get $sx local.get $sy local.get $cp local.get $av call $sampleRGB))
                  local.get $q
                  local.get $t call $radT i32.store))
                local.get $t local.get $dt f64.add local.set $t
                local.get $u local.get $du f64.add local.set $u
                local.get $hh local.get $dh f64.add local.set $hh
                global.get $GROW f64.const 0 f64.eq
                (if (then
                  local.get $sx local.get $dsx f64.add local.set $sx
                  local.get $sy local.get $dsy f64.add local.set $sy)
                  (else
                    local.get $s local.get $ds f64.add local.set $s
                    global.get $UMID
                    local.get $u global.get $UMID f64.sub local.get $s f64.div f64.add local.set $usrc
                    global.get $AX local.get $usrc global.get $LX f64.mul f64.add
                    local.get $hh global.get $NX f64.mul f64.add local.set $sx
                    global.get $AY local.get $usrc global.get $LY f64.mul f64.add
                    local.get $hh global.get $NY f64.mul f64.add local.set $sy))))
            local.get $p i32.const 4 i32.add local.set $p
            local.get $q i32.const 4 i32.add local.set $q
            local.get $cp i32.const 12 i32.add local.set $cp
            local.get $x i32.const 1 i32.add local.set $x
            br $fxl))
        local.get $y i32.const 1 i32.add local.set $y
        br $fyl))

    ;; ---- 渐进模糊 ----
    global.get $BLUR f64.const 0.001 f64.gt
    (if (then
      call $blurH
      call $blurV))

    ;; ---- 合成 ----
    global.get $ONLY
    (if (then global.get $PIX global.get $TOTAL call $zeroMem))
    local.get $fy0 local.set $y
    (block $cyend
      (loop $cyl
        local.get $y local.get $fy1 i32.gt_s br_if $cyend
        local.get $fx0 f64.convert_i32_s global.get $AX f64.sub
        global.get $NX f64.mul
        local.get $y f64.convert_i32_s global.get $AY f64.sub
        global.get $NY f64.mul f64.add global.get $INVWN f64.mul local.set $t0
        global.get $NX global.get $INVWN f64.mul local.set $dt
        local.get $t0 local.set $t
        local.get $fx0 local.set $x
        global.get $COL
        local.get $y global.get $W i32.mul local.get $fx0 i32.add i32.const 12 i32.mul i32.add
        local.set $cp
        (block $cxend
          (loop $cxl
            local.get $x local.get $fx1 i32.gt_s br_if $cxend
            global.get $BENDON
            (if (then
              local.get $x f64.convert_i32_s
              local.get $y f64.convert_i32_s
              call $bendT local.set $t))
            global.get $FADEON
            (if (result f64)
              (then local.get $t call $fadeT)
              (else f64.const 1))
            global.get $FADEK f64.mul
            f32.demote_f64 local.set $fade
            global.get $SH
            local.get $y global.get $W i32.mul local.get $x i32.add
            i32.const 2 i32.shl i32.add
            f32.load local.get $fade f32.mul local.set $sa
            local.get $sa f32.const 0 f32.max f32.const 1 f32.min local.set $sa
            local.get $y global.get $W i32.mul local.get $x i32.add
            i32.const 4 i32.shl global.get $PIX i32.add local.set $p
            global.get $SRC_MODE i32.const 2 i32.eq
            (if (then
              local.get $cp f32.load local.set $cr
              local.get $cp f32.load offset=4 local.set $cg
              local.get $cp f32.load offset=8 local.set $cb)
              (else
                global.get $CRF local.set $cr
                global.get $CGF local.set $cg
                global.get $CBF local.set $cb))
            global.get $ONLY
            (if (then
              local.get $cr local.get $sa f32.mul local.set $or
              local.get $cg local.get $sa f32.mul local.set $og
              local.get $cb local.get $sa f32.mul local.set $ob
              local.get $sa local.set $oa)
              (else
                local.get $p f32.load local.set $sr
                local.get $p f32.load offset=4 local.set $sg
                local.get $p f32.load offset=8 local.set $sb
                local.get $p f32.load offset=12 local.set $saa
                global.get $BEHIND
                (if (then
                  f32.const 1 local.get $saa f32.sub local.set $inv
                  local.get $sr
                  local.get $cr local.get $sa f32.mul local.get $inv f32.mul
                  f32.add local.set $or
                  local.get $sg
                  local.get $cg local.get $sa f32.mul local.get $inv f32.mul
                  f32.add local.set $og
                  local.get $sb
                  local.get $cb local.get $sa f32.mul local.get $inv f32.mul
                  f32.add local.set $ob
                  local.get $saa local.get $sa local.get $inv f32.mul f32.add local.set $oa)
                  (else
                    f32.const 1 local.get $sa f32.sub local.set $inv
                    local.get $cr local.get $sa f32.mul
                    local.get $sr local.get $inv f32.mul f32.add local.set $or
                    local.get $cg local.get $sa f32.mul
                    local.get $sg local.get $inv f32.mul f32.add local.set $og
                    local.get $cb local.get $sa f32.mul
                    local.get $sb local.get $inv f32.mul f32.add local.set $ob
                    local.get $sa
                    local.get $saa local.get $inv f32.mul f32.add local.set $oa))))
            local.get $p
            local.get $or f32.const 0 f32.max f32.const 1 f32.min f32.store
            local.get $p
            local.get $og f32.const 0 f32.max f32.const 1 f32.min f32.store offset=4
            local.get $p
            local.get $ob f32.const 0 f32.max f32.const 1 f32.min f32.store offset=8
            local.get $p
            local.get $oa f32.const 0 f32.max f32.const 1 f32.min f32.store offset=12
            global.get $BENDON
            i32.eqz
            (if (then local.get $t local.get $dt f64.add local.set $t))
            local.get $cp i32.const 12 i32.add local.set $cp
            local.get $x i32.const 1 i32.add local.set $x
            br $cxl))
        local.get $y i32.const 1 i32.add local.set $y
        br $cyl))
    i32.const 0)
)
