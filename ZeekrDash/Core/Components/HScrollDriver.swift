//
//  HScrollDriver.swift
//  ZeekrDash
//
//  横向滚动驱动：用真正的 UIScrollView 提供手势与惯性，
//  SwiftUI 侧只读它的 contentOffset。
//
//  为什么不用 SwiftUI 的 ScrollView：行程页两张图在**两张独立的玻璃卡**里，
//  各自一个 ScrollView 时无法把偏移量按像素同步（`scrollTo` 只能跳到整根柱）。
//  这里每张图各拿一个 UIScrollView（原生惯性、回弹都在），
//  再把两个 offset 绑到同一个 Binding 上 —— 滑哪张，另一张立刻跟到同一像素。
//
//  为什么不用自定义 DragGesture：那样没有惯性，松手是 easeOut 而不是自然减速。
//

import SwiftUI
import UIKit

struct HScrollDriver: UIViewRepresentable {

    /// 与另一张图共享的横向偏移（内容坐标）
    @Binding var offset: CGFloat
    /// 内容总宽
    let contentWidth: CGFloat
    /// 点一下：回调**内容坐标**的 x，由调用方换算成第几根柱
    var onTap: ((CGFloat) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceVertical = false
        scroll.alwaysBounceHorizontal = true
        scroll.backgroundColor = .clear
        scroll.contentSize = CGSize(width: max(contentWidth, 1), height: 1)
        scroll.delegate = context.coordinator

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.delegate = context.coordinator
        scroll.addGestureRecognizer(tap)

        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.parent = self
        scroll.contentSize = CGSize(width: max(contentWidth, 1), height: 1)

        // 首次布局时 bounds 还是 0，先逼一次布局，否则「默认停在最右」会被钳成 0
        if scroll.bounds.width == 0 { scroll.layoutIfNeeded() }

        // 另一张图滚动 / 程序设置偏移：这里跟随（拖动中不抢）
        if !context.coordinator.dragging,
           abs(scroll.contentOffset.x - offset) > 0.5 {
            let maxX = max(0, scroll.contentSize.width - scroll.bounds.width)
            scroll.setContentOffset(CGPoint(x: min(max(0, offset), maxX), y: 0), animated: false)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {

        var parent: HScrollDriver
        var dragging = false

        init(_ parent: HScrollDriver) { self.parent = parent }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let x = scrollView.contentOffset.x
            if abs(parent.offset - x) > 0.5 {
                parent.offset = x
            }
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { dragging = true }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { dragging = false }
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { dragging = false }

        /// 竖向为主的滑动不拦截 —— 页面本身还要能上下滚
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if let pan = gestureRecognizer as? UIPanGestureRecognizer, let view = pan.view {
                let velocity = pan.velocity(in: view)
                if abs(velocity.y) > abs(velocity.x) { return false }
            }
            return true
        }

        /// 拖动与点击互斥：拖动开始了就不要再当点击处理
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view else { return }
            // UIScrollView 的 bounds.origin == contentOffset，
            // 所以 location(in:) 已经是**内容坐标**，不要再加一次
            let point = gesture.location(in: view)
            parent.onTap?(point.x)
        }
    }
}
