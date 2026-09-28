/**
 * 返回键消费链（第九轮新增）。
 *
 * 背景：本工程用显式路由栈，pages/Index.ets 的 onBackPress() 统一走 Router.pop()。
 * 但有些页面内部还有「子页 / 子状态」（例如设置页的账号子页、语言子页），上游 Android 端
 * 这类子页是逐级返回的（BackHandler），鸿蒙端此前会**直接退出整个页面**。
 *
 * 做法：页面把「能否消费这次返回」注册进来；根页面先问它，被消费掉就不再 pop 路由。
 * 只允许**一个**消费者（当前只有设置页有子页），后注册覆盖先注册 —— 页面必须在
 * aboutToDisappear 里注销，避免留下悬空回调。
 */

/** 返回 true 表示「这次返回已被页面内部消费」，根页面不要再 pop 路由。 */
let activeConsumer: (() => boolean) | undefined = undefined;

export function registerBackConsumer(consumer: (() => boolean) | undefined): void {
  activeConsumer = consumer;
}

/**
 * 按**身份**注销（第十轮新增）：只有当前登记的消费者就是自己时才清空。
 *
 * 为什么需要它：早先页面统一用 `registerBackConsumer(undefined)` 注销，而注册表是**单槽**
 * （后注册覆盖先注册）—— 于是「设置抽屉关闭时注销」会把**首页自己注册的消费者一起清掉**，
 * 表现为「抽屉关过一次之后，首页的返回键消费逻辑就再也不生效了」，而且不报错。
 * 页面一律改用本函数注销，并在 aboutToDisappear 里传入自己当初注册的那个函数引用。
 */
export function unregisterBackConsumer(consumer: (() => boolean) | undefined): void {
  if (consumer === undefined) {
    activeConsumer = undefined;
    return;
  }
  if (activeConsumer === consumer) {
    activeConsumer = undefined;
  }
}

export function consumeBackPress(): boolean {
  const consumer = activeConsumer;
  if (consumer === undefined) {
    return false;
  }
  return consumer();
}