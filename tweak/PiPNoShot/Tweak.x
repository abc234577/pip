// PiPNoShot — 让「画中画(PiP)悬浮小窗」在截图/录屏/AirPlay 镜像中变黑，保护隐私。
//
// 背景（为什么 App 自身的防截图盖不住 PiP）：
//   App 内用 isSecureTextEntry 的 UITextField 安全画布(渲染服务器的 secure CAContext)
//   能让自己图层在截屏里变黑。但 PiP 悬浮窗不是 App 画的——系统 PIPAgent 进程
//   从我们 enqueue 的 CMSampleBuffer 重新合成渲染，安全上下文不会跟着过去，所以
//   悬浮窗照样能被截。
//
// 本插件的做法（与 HeeeNoScreenShotView 同一个原理，只是搬到 PIPAgent 里执行）：
//   在 PIPAgent 的「画中画内容视图控制器」布局时，建一个 secureTextEntry 的
//   UITextField，取它第一个子视图(_UITextLayoutCanvasView，寄宿在渲染服务器的
//   安全上下文)作为安全画布，把 PiP 的真实内容视图搬进这个画布 → 渲染服务器在做
//   截图/录屏/镜像合成时会跳过安全上下文 → 悬浮窗区域变黑，屏幕上正常显示。
//
// 首个版本同时把发现的类名与视图树 NSLog 出来(前缀 [PiPNoShot])，装机后可据此
// 核对/微调目标类，再定版。

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static const char kSecuredKey;      // 关联对象：标记某内容视图已被安全化，避免重复搬运
static const char kOwnerFieldKey;   // 关联对象：让安全画布强引用它的宿主 UITextField

// 候选的「PiP 内容视图控制器」类名（不同系统版本命名略有差异，存在哪个就 hook 哪个）
static const char *kCandidateVCs[] = {
    "PGPictureInPictureViewController",          // AVKit 私有：悬浮窗内容 VC（常见）
    "PGPictureInPictureContentViewController",
    "AVPictureInPictureContentViewController",
    "PGPictureInPicturePlayerLayerViewController",
    NULL
};

// 原始 viewDidLayoutSubviews 实现表：Class(name 存指针) -> 原 IMP
static NSMutableDictionary<NSString *, NSValue *> *gOrigIMPs;

// 建一个“安全画布”并返回（画布本身是 _UITextLayoutCanvasView）
static UIView *HKMakeSecureCanvas(UIView *host) {
    if (!host) return nil;
    UITextField *tf = [[UITextField alloc] initWithFrame:host.bounds];
    tf.secureTextEntry = YES;
    tf.userInteractionEnabled = NO;
    tf.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [host addSubview:tf];
    [host sendSubviewToBack:tf];

    UIView *canvas = tf.subviews.firstObject;   // _UITextLayoutCanvasView：安全上下文
    if (!canvas) { [tf removeFromSuperview]; return nil; }
    canvas.userInteractionEnabled = YES;
    canvas.frame = host.bounds;
    canvas.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // 让画布强引用 textfield，避免 tf 被释放后安全上下文失效
    objc_setAssociatedObject(canvas, &kOwnerFieldKey, tf, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return canvas;
}

// 把一个内容视图的真实子视图搬进安全画布（HeeeNoScreenShotView 同款动作）
static void HKSecureContentView(UIView *content) {
    if (!content) return;
    if (objc_getAssociatedObject(content, &kSecuredKey)) return;

    UIView *canvas = HKMakeSecureCanvas(content);
    if (!canvas) return;
    UITextField *ownerTF = (UITextField *)canvas.superview;   // 我们刚加进去的 secure textfield

    NSArray<UIView *> *subs = [content.subviews copy];
    NSUInteger moved = 0;
    for (UIView *v in subs) {
        if (v == ownerTF) continue;        // 跳过安全 textfield 自己
        if (v == canvas) continue;
        [canvas addSubview:v];             // 真实内容 → 安全画布
        moved++;
    }

    if (moved == 0) {
        // 内容不是靠子视图、而是靠 content 自身的 layer 直接画(如 AVSampleBufferDisplayLayer)。
        // 退一步：把 content 整个搬进它父视图里的安全画布。
        UIView *sup = content.superview;
        if (sup && !objc_getAssociatedObject(sup, &kSecuredKey)) {
            [ownerTF removeFromSuperview];                 // 撤掉刚才加在 content 上的
            UIView *canvas2 = HKMakeSecureCanvas(sup);
            if (canvas2) {
                CGRect f = content.frame;
                [canvas2 addSubview:content];
                content.frame = canvas2.bounds;
                content.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                (void)f;
                objc_setAssociatedObject(sup, &kSecuredKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(content, &kSecuredKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                NSLog(@"[PiPNoShot] secured by moving content view itself into parent secure canvas");
                return;
            }
        }
    }

    objc_setAssociatedObject(content, &kSecuredKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSLog(@"[PiPNoShot] secured content view %@ (moved %lu subviews)",
          NSStringFromClass(content.class), (unsigned long)moved);
}

// 一次性把视图子树打印出来，便于装机后核对结构
static void HKDumpTree(UIView *v, int depth) {
    if (!v || depth > 4) return;
    NSMutableString *pad = [NSMutableString string];
    for (int i = 0; i < depth; i++) [pad appendString:@"  "];
    NSLog(@"[PiPNoShot][tree]%@%@ frame=%@", pad, NSStringFromClass(v.class),
          NSStringFromCGRect(v.frame));
    for (UIView *s in v.subviews) HKDumpTree(s, depth + 1);
}

// 替换版 viewDidLayoutSubviews
static void hk_viewDidLayoutSubviews(id self, SEL _cmd) {
    // 找到并调用对应类的原实现
    Class c = object_getClass(self);
    IMP orig = NULL;
    while (c) {
        NSValue *val = gOrigIMPs[NSStringFromClass(c)];
        if (val) { orig = (IMP)[val pointerValue]; break; }
        c = class_getSuperclass(c);
    }
    if (orig) ((void(*)(id, SEL))orig)(self, _cmd);

    @try {
        UIView *content = [self performSelector:@selector(view)];
        static dispatch_once_t dumpOnce;
        dispatch_once(&dumpOnce, ^{
            NSLog(@"[PiPNoShot] PiP content VC = %@", NSStringFromClass([self class]));
            HKDumpTree(content, 0);
        });
        HKSecureContentView(content);
    } @catch (__unused NSException *e) {}
}

%ctor {
    @autoreleasepool {
        gOrigIMPs = [NSMutableDictionary dictionary];
        SEL sel = @selector(viewDidLayoutSubviews);
        BOOL hookedAny = NO;
        for (int i = 0; kCandidateVCs[i]; i++) {
            Class c = objc_getClass(kCandidateVCs[i]);
            if (!c) continue;
            Method m = class_getInstanceMethod(c, sel);
            if (!m) continue;
            IMP old = method_getImplementation(m);
            gOrigIMPs[NSStringFromClass(c)] = [NSValue valueWithPointer:old];
            method_setImplementation(m, (IMP)hk_viewDidLayoutSubviews);
            hookedAny = YES;
            NSLog(@"[PiPNoShot] hooked %s -viewDidLayoutSubviews", kCandidateVCs[i]);
        }
        if (!hookedAny) {
            NSLog(@"[PiPNoShot] no PiP content VC class found in this process (%@)",
                  [NSProcessInfo processInfo].processName);
        }
    }
}
