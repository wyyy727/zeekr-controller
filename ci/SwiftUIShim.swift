import Observation
import Foundation


// ── 基础协议 ──
@MainActor
public protocol View {
    associatedtype Body: View
    @ViewBuilder @MainActor var body: Body { get }
}
/// 桩便利：叶子类型（Color/Image/Text…）无需逐个声明 body。
/// 用 associatedtype 的默认值把 Body 固定为 EmptyView，避免 Never 循环约束。
public extension View where Body == EmptyView {
    @MainActor var body: EmptyView { EmptyView() }
}

// ── 基础类型 ──
nonisolated public struct Color: View, Equatable, Hashable, Sendable {
    public struct RGBColorSpace: Sendable { public static let sRGB = RGBColorSpace(); public static let displayP3 = RGBColorSpace() }
    nonisolated public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {}
    nonisolated public init(_ space: RGBColorSpace, red: Double, green: Double, blue: Double, opacity: Double = 1) {}
    public static let clear = Color(red: 0, green: 0, blue: 0, opacity: 0)
    public static let white = Color(red: 1, green: 1, blue: 1)
    public static let black = Color(red: 0, green: 0, blue: 0)
    public static let gray = Color(red: 0.5, green: 0.5, blue: 0.5)
    public static let red = Color(red: 1, green: 0, blue: 0)
    public static let blue = Color(red: 0, green: 0, blue: 1)
    public static let green = Color(red: 0, green: 1, blue: 0)
    public static let orange = Color(red: 1, green: 0.5, blue: 0)
    public static let yellow = Color(red: 1, green: 1, blue: 0)
    public static let primary = Color(red: 0, green: 0, blue: 0)
    public static let secondary = Color(red: 0.5, green: 0.5, blue: 0.5)
    public static let accentColor = Color(red: 0, green: 0, blue: 1)
    public init(_ name: String) {}
    public func opacity(_ o: Double) -> Color { self }
}

@MainActor
public enum ColorScheme: Sendable { case light, dark }

nonisolated public struct Font: Sendable {
    public static let body = Font()
    public static let caption = Font()
    public static let caption2 = Font()
    public static let footnote = Font()
    public static let headline = Font()
    public func bold() -> Font { self }
    public func italic() -> Font { self }
    public func weight(_ w: Font.Weight) -> Font { self }
    public func monospacedDigit() -> Font { self }
    public static let subheadline = Font()
    public static let title = Font()
    public static let title2 = Font()
    public static let title3 = Font()
    public static let largeTitle = Font()
    public static func system(size: Double, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font { Font() }
    public static func system(_ style: Font.TextStyle, design: Font.Design = .default) -> Font { Font() }
    public enum Weight: Sendable { case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black }
    public enum Design: Sendable { case `default`, serif, rounded, monospaced }
    public enum TextStyle: Sendable { case largeTitle, title, title2, title3, headline, subheadline, body, callout, footnote, caption, caption2 }
}

nonisolated public struct Image: View {
    public init(systemName: String) {}
    public init(_ name: String) {}
    public static func systemName(_ n: String) -> Image { Image(systemName: n) }
}

nonisolated public struct Text: View {
    public init(_ content: String) { _ = content }
    public init(verbatim: String) {}
    public func font(_ f: Font?) -> Text { self }
    public func fontWeight(_ w: Font.Weight?) -> Text { self }
    public func foregroundStyle<S>(_ style: S) -> Text { self }
    public func foregroundColor(_ c: Color?) -> Text { self }
    public func monospacedDigit() -> Text { self }
    public func multilineTextAlignment(_ a: TextAlignment) -> Text { self }
    public func lineLimit(_ n: Int?) -> Text { self }
    public func minimumScaleFactor(_ f: Double) -> Text { self }
    public func bold() -> Text { self }
    public func kerning(_ k: Double) -> Text { self }
}

@MainActor
public enum TextAlignment: Sendable { case leading, center, trailing }
@MainActor
public struct TextCase: Sendable { public static let uppercase = TextCase() }

@MainActor
public protocol LabelStyle {}
@MainActor
public struct DefaultLabelStyle: LabelStyle {}
nonisolated public struct Label: View {
    public init(_ title: String, systemImage: String) {}
    public init(_ title: String, image: String) {}
    public init(@ViewBuilder title: () -> some View, @ViewBuilder icon: () -> some View) {}
    public func labelStyle<S>(_ style: S) -> Label { self }
    public func font(_ f: Font?) -> Label { self }
    public func foregroundStyle<S>(_ s: S) -> Label { self }
}
@MainActor
public struct TitleAndIconLabelStyle: LabelStyle, Sendable { public init() {} }
@MainActor
public struct IconOnlyLabelStyle: LabelStyle { public init() {} }
extension LabelStyle where Self == TitleAndIconLabelStyle {
    public static var titleAndIcon: TitleAndIconLabelStyle { TitleAndIconLabelStyle() }
}

// ── 布局容器 ──
@MainActor
public struct VStack<Content: View>: View {
    public init(alignment: HorizontalAlignment = .center, spacing: Double? = nil, @ViewBuilder content: () -> Content) {}
}
@MainActor
public struct HStack<Content: View>: View {
    public init(alignment: VerticalAlignment = .center, spacing: Double? = nil, @ViewBuilder content: () -> Content) {}
}
@MainActor
public struct ZStack<Content: View>: View {
    public init(alignment: Alignment = .center, @ViewBuilder content: () -> Content) {}
}
@MainActor
public struct LazyVGrid<Content: View>: View {
    public init(columns: [GridItem], alignment: HorizontalAlignment = .center, spacing: Double? = nil, pinnedViews: PinnedScrollableViews = .init(), @ViewBuilder content: () -> Content) {}
}
@MainActor
public struct LazyVStack<Content: View>: View {
    public init(alignment: HorizontalAlignment = .center, spacing: Double? = nil, pinnedViews: PinnedScrollableViews = .init(), @ViewBuilder content: () -> Content) {}
}
@MainActor
public struct GridItem: Sendable {
    public init(_ size: GridItem.Size = .flexible(), spacing: Double? = nil, alignment: Alignment? = nil) {}
    public enum Size: Sendable { case fixed(Double), flexible(Double? = nil), adaptive(minimum: Double, maximum: Double) }
    public static func flexible() -> GridItem { GridItem() }
    public static func fixed(_ s: Double) -> GridItem { GridItem(.fixed(s)) }
    public static func adaptive(minimum: Double, maximum: Double = .infinity) -> GridItem { GridItem() }
}
@MainActor
public struct Grid<Content: View>: View {
    public init(alignment: Alignment = .center, horizontalSpacing: Double? = nil, verticalSpacing: Double? = nil, @ViewBuilder content: () -> Content) {}
}
@MainActor
public struct GridRow<Content: View>: View {
    public init(alignment: VerticalAlignment = .center, @ViewBuilder content: () -> Content) {}
}
@MainActor
public struct PinnedScrollableViews: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let sectionHeaders = PinnedScrollableViews(rawValue: 1)
}
@MainActor
public struct ScrollView<Content: View>: View {
    public init(_ axes: Axis.Set = .vertical, showsIndicators: Bool = true, @ViewBuilder content: () -> Content) {}
}
nonisolated public struct Axis: OptionSet, Sendable {
    public struct Set: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let horizontal = Set(rawValue: 1)
        public static let vertical = Set(rawValue: 2)
    }
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let horizontal = Axis(rawValue: 1)
    public static let vertical = Axis(rawValue: 2)
}
@MainActor
public struct GeometryReader<Content: View>: View {
    public init(@ViewBuilder content: @escaping (GeometryProxy) -> Content) {}
}
@MainActor
public struct GeometryProxy: Sendable {
    public var size: CGSize { .zero }
    public func frame(in: CoordinateSpace) -> CGRect { .zero }
}
@MainActor
public struct CoordinateSpace: Sendable { public static let local = CoordinateSpace(); public static let global = CoordinateSpace() }

nonisolated public struct Spacer: View { public init(minLength: Double? = nil) {} }
nonisolated public struct Divider: View { public init() {} }
@MainActor
public struct Group<Content: View>: View {
    public init(@ViewBuilder content: () -> Content) {}
}
@MainActor
public struct Menu<Label: View, Content: View>: View {
    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {}
}

@MainActor
public struct Section<Content: View, Header: View, Footer: View>: View {
    public init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header, @ViewBuilder footer: () -> Footer) {}
}
@MainActor
public struct AnyView: View {
    public init<V: View>(_ view: V) {}
}

// ── 形状 ──
@MainActor
public protocol Shape: View {}
nonisolated public struct Circle: Shape { public init() {} }
nonisolated public struct Rectangle: Shape { public init() {} }
public struct Capsule: Shape { public init() {} }
nonisolated public struct RoundedRectangle: Shape {
    public init(cornerRadius: Double, style: RoundedCornerStyle = .circular) {}
    public init(cornerSize: CGSize, style: RoundedCornerStyle = .circular) {}
}
@MainActor
public enum RoundedCornerStyle: Sendable { case circular, continuous }

nonisolated public struct LinearGradient: View {
    public init(colors: [Color], startPoint: UnitPoint, endPoint: UnitPoint) {}
    public init(stops: [Gradient.Stop], startPoint: UnitPoint, endPoint: UnitPoint) {}
    public init(gradient: Gradient, startPoint: UnitPoint, endPoint: UnitPoint) {}
}
nonisolated public struct RadialGradient: View {
    public init(colors: [Color], center: UnitPoint, startRadius: Double, endRadius: Double) {}
    public init(gradient: Gradient, center: UnitPoint, startRadius: Double, endRadius: Double) {}
}
nonisolated public struct Gradient: Sendable {
    public init(colors: [Color]) {}
    public init(stops: [Gradient.Stop]) {}
    public struct Stop: Sendable { public init(color: Color, location: Double) {} }
}
public typealias CGFloat = Double

nonisolated public struct UnitPoint: Sendable {
    public init() {}
    public init(x: Double, y: Double) {}
    public static let center = UnitPoint()
    public static let top = UnitPoint()
    public static let bottom = UnitPoint()
    public static let leading = UnitPoint()
    public static let trailing = UnitPoint()
    public static let topLeading = UnitPoint()
    public static let topTrailing = UnitPoint()
    public static let bottomLeading = UnitPoint()
    public static let bottomTrailing = UnitPoint()
}

// ── 对齐 ──
nonisolated public struct HorizontalAlignment: Sendable {
    public static let center = HorizontalAlignment()
    public static let leading = HorizontalAlignment()
    public static let trailing = HorizontalAlignment()
}
nonisolated public struct VerticalAlignment: Sendable {
    public static let center = VerticalAlignment()
    public static let top = VerticalAlignment()
    public static let bottom = VerticalAlignment()
    public static let firstTextBaseline = VerticalAlignment()
    public static let lastTextBaseline = VerticalAlignment()
}
nonisolated public struct Alignment: Sendable {
    public static let center = Alignment()
    public static let leading = Alignment()
    public static let trailing = Alignment()
    public static let top = Alignment()
    public static let bottom = Alignment()
    public static let topLeading = Alignment()
    public static let topTrailing = Alignment()
    public static let bottomLeading = Alignment()
    public static let bottomTrailing = Alignment()
}

nonisolated public struct CGSize: Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
    public static let zero = CGSize(width: 0, height: 0)
}
nonisolated public struct CGPoint: Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public static let zero = CGPoint(x: 0, y: 0)
}
nonisolated public struct CGRect: Sendable {
    public var origin: CGPoint
    public var size: CGSize
    public init(origin: CGPoint, size: CGSize) { self.origin = origin; self.size = size }
    public static let zero = CGRect(origin: .zero, size: .zero)
}
nonisolated public struct EdgeInsets: Sendable {
    public var top: Double, leading: Double, bottom: Double, trailing: Double
    public init(top: Double = 0, leading: Double = 0, bottom: Double = 0, trailing: Double = 0) {
        self.top = top; self.leading = leading; self.bottom = bottom; self.trailing = trailing
    }
    public static let zero = EdgeInsets()
}

// ── 按钮 ──
@MainActor
public struct Button<Label: View>: View {
    public init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {}
    public init(_ title: String, action: @escaping () -> Void) where Label == Text {}
    public init(_ title: String, systemImage: String, action: @escaping () -> Void) where Label == Label {}
    public func buttonStyle<S: ButtonStyle>(_ style: S) -> Button { self }
    public func disabled(_ b: Bool) -> Button { self }
    public func tint(_ c: Color?) -> Button { self }
}
@MainActor
public protocol ButtonStyle {
    associatedtype Body: View
    @ViewBuilder func makeBody(configuration: Self.Configuration) -> Self.Body
    typealias Configuration = ButtonStyleConfiguration
}
@MainActor
public struct ButtonStyleConfiguration {
    public struct Label: View { public init() {} }
    public let label: Label
    public let isPressed: Bool
}
@MainActor
public struct PrimitiveButtonStyleConfiguration {
    public let label: ButtonStyleConfiguration.Label
}
@MainActor
public struct DefaultButtonStyle: ButtonStyle {
    public func makeBody(configuration: ButtonStyleConfiguration) -> some View { configuration.label }
}
@MainActor
public struct PlainButtonStyle: ButtonStyle {
    public func makeBody(configuration: ButtonStyleConfiguration) -> some View { configuration.label }
}
@MainActor
public struct BorderlessButtonStyle: ButtonStyle {
    public func makeBody(configuration: ButtonStyleConfiguration) -> some View { configuration.label }
}
extension ButtonStyle where Self == DefaultButtonStyle { public static var automatic: DefaultButtonStyle { DefaultButtonStyle() } }
extension ButtonStyle where Self == PlainButtonStyle { public static var plain: PlainButtonStyle { PlainButtonStyle() } }
extension ButtonStyle where Self == BorderlessButtonStyle { public static var borderless: BorderlessButtonStyle { BorderlessButtonStyle() } }

// ── 控件 ──
@MainActor
public struct Toggle<Label: View>: View {
    public init(isOn: Binding<Bool>, @ViewBuilder label: () -> Label) {}
    public init(_ title: String, isOn: Binding<Bool>) where Label == Text {}
    public func tint(_ c: Color?) -> Toggle { self }
    public func labelsHidden() -> Toggle { self }
}
@MainActor
public struct ProgressView<Label: View, CurrentValueLabel: View>: View {
    public init() where Label == EmptyView, CurrentValueLabel == EmptyView {}
    public init(@ViewBuilder label: () -> Label, @ViewBuilder currentValueLabel: () -> CurrentValueLabel) {}
    public func progressViewStyle<S>(_ s: S) -> ProgressView { self }
    public func tint(_ c: Color?) -> ProgressView { self }
    public func scaleEffect(_ s: Double) -> ProgressView { self }
}
nonisolated public struct EmptyView: View { public init() {}; public var body: EmptyView { self } }
@MainActor
public struct CircularProgressViewStyle: Sendable { public init() {} }

// ── Canvas ──
nonisolated public struct Canvas<Symbols: View>: View {
    public init(opaque: Bool = false, colorMode: ColorRenderingMode = .nonLinear, rendersAsynchronously: Bool = false, renderer: @escaping (inout GraphicsContext, CGSize) -> Void, @ViewBuilder symbols: () -> Symbols) {}
}
extension Canvas where Symbols == EmptyView {
    public init(opaque: Bool = false, colorMode: ColorRenderingMode = .nonLinear, rendersAsynchronously: Bool = false, renderer: @escaping (inout GraphicsContext, CGSize) -> Void) {}
}
@MainActor
public enum ColorRenderingMode: Sendable { case nonLinear, linear, extendedLinear }
nonisolated public struct GraphicsContext {
    public var strokeStyle: StrokeStyle
    public func stroke(_ path: Path, with shading: GraphicsContext.Shading, lineWidth: Double = 1) {}
    public func fill(_ path: Path, with shading: GraphicsContext.Shading) {}
    public func draw(_ image: Image, in rect: CGRect) {}
    public enum Shading: Sendable { case color(Color); public static func linearGradient(_ g: Gradient, startPoint: CGPoint, endPoint: CGPoint) -> Shading { .color(.black) } }
}
nonisolated public struct Path: Sendable {
    public init() {}
    public init(_ callback: (inout Path) -> Void) {}
    public mutating func move(to p: CGPoint) {}
    public mutating func addLine(to p: CGPoint) {}
    public mutating func addArc(center: CGPoint, radius: Double, startAngle: Angle, endAngle: Angle, clockwise: Bool) {}
    public mutating func addArc(tangent1End: CGPoint, tangent2End: CGPoint, radius: Double) {}
    public mutating func addQuadCurve(to p: CGPoint, control: CGPoint) {}
    public mutating func addCurve(to p: CGPoint, control1: CGPoint, control2: CGPoint) {}
    public mutating func addRect(_ r: CGRect) {}
    public mutating func addRoundedRect(in r: CGRect, cornerSize: CGSize) {}
    public mutating func addEllipse(in r: CGRect) {}
    public mutating func closeSubpath() {}
    public func strokedPath(_ style: StrokeStyle) -> Path { self }
}
nonisolated public struct StrokeStyle: Sendable {
    public var lineWidth: Double
    public var lineCap: CGLineCap
    public var lineJoin: CGLineJoin
    public var miterLimit: Double
    public var dash: [Double]
    public var dashPhase: Double
    public init(lineWidth: Double = 1, lineCap: CGLineCap = .butt, lineJoin: CGLineJoin = .miter, miterLimit: Double = 10, dash: [Double] = [], dashPhase: Double = 0) {
        self.lineWidth = lineWidth; self.lineCap = lineCap; self.lineJoin = lineJoin
        self.miterLimit = miterLimit; self.dash = dash; self.dashPhase = dashPhase
    }
}
@MainActor
public enum CGLineCap: Sendable { case butt, round, square }
@MainActor
public enum CGLineJoin: Sendable { case miter, round, bevel }
nonisolated public struct Angle: Sendable {
    public var degrees: Double
    public init(degrees: Double) { self.degrees = degrees }
    public static func degrees(_ d: Double) -> Angle { Angle(degrees: d) }
    public static let zero = Angle(degrees: 0)
}

// ── 属性包装器与环境 ──
@propertyWrapper public struct State<Value>: DynamicProperty {
    public var wrappedValue: Value { get { fatalError() } nonmutating set {} }
    public var projectedValue: Binding<Value> { fatalError() }
    public init(wrappedValue: Value) { _ = wrappedValue }
    public init(initialValue: Value) { _ = initialValue }
}
@propertyWrapper @dynamicMemberLookup
public struct Binding<Value>: DynamicProperty {
    public var wrappedValue: Value { get { fatalError() } nonmutating set {} }
    public var projectedValue: Binding<Value> { self }
    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {}
    public init(_ value: Value) { _ = value }
    public static func constant(_ v: Value) -> Binding<Value> { Binding(get: { v }, set: { _ in }) }
    public subscript<Subject>(dynamicMember keyPath: WritableKeyPath<Value, Subject>) -> Binding<Subject> {
        Binding<Subject>(get: { fatalError() }, set: { _ in })
    }
    public subscript<Subject>(dynamicMember keyPath: ReferenceWritableKeyPath<Value, Subject>) -> Binding<Subject> where Value: AnyObject {
        Binding<Subject>(get: { fatalError() }, set: { _ in })
    }
}
@MainActor
public protocol DynamicProperty {}
@propertyWrapper public struct AppStorage<Value>: DynamicProperty {
    public var wrappedValue: Value { get { fatalError() } nonmutating set {} }
    public init(wrappedValue: Value, _ key: String) { _ = wrappedValue }
}
@propertyWrapper public struct Environment<Value>: DynamicProperty {
    public var wrappedValue: Value { fatalError() }
    public var projectedValue: Environment<Value> { self }
    public init(_ keyPath: KeyPath<EnvironmentValues, Value>) {}
    /// iOS 17+ 的 Observable 注入形式：@Environment(AppStore.self)
    public init(_ objectType: Value.Type) {}
    public init<T>(_ objectType: T.Type) where Value == T? {}
}
@propertyWrapper public struct Namespace: DynamicProperty {
    public var wrappedValue: Namespace.ID { Namespace.ID() }
    public struct ID: Hashable, Sendable {}
    public init() {}
}
public enum ScenePhase: Sendable, Equatable { case active, inactive, background }

/// 焦点状态包装器（签名对齐 SwiftUI.FocusState）
@propertyWrapper @MainActor
public struct FocusState<Value: Hashable>: DynamicProperty {
    public var wrappedValue: Value { get { fatalError() } nonmutating set {} }
    public var projectedValue: FocusState<Value>.Binding { fatalError() }
    public init() {}
    @MainActor
    public struct Binding: Hashable {
        public var wrappedValue: Value { get { fatalError() } nonmutating set {} }
        public init() {}
    }
}

@MainActor
public struct EnvironmentValues {
    public var colorScheme: ColorScheme
    public var scenePhase: ScenePhase
    public var dismiss: DismissAction
    public var horizontalSizeClass: UserInterfaceSizeClass?
    public var verticalSizeClass: UserInterfaceSizeClass?
    public var accessibilityReduceMotion: Bool
    public var isEnabled: Bool
}
@MainActor
public struct DismissAction { public func callAsFunction() {} }
@MainActor
public enum UserInterfaceSizeClass: Sendable { case compact, regular }
@MainActor
public protocol EnvironmentKey {
    associatedtype Value
    static var defaultValue: Value { get }
}
extension EnvironmentValues {
    public subscript<K: EnvironmentKey>(_: K.Type) -> Bool {
        get { false }
        set { _ = newValue }
    }
}
@MainActor
public struct EnvironmentObject<ObjectType: AnyObject>: DynamicProperty {
    public var wrappedValue: ObjectType { fatalError() }
}
@MainActor
public struct ObservableObject {}
@MainActor
public protocol Observable {}
@MainActor
/// Bindable：@Observable 对象的 Binding 动态成员查找（签名对齐 SwiftUI.Bindable）
@dynamicMemberLookup
public struct Bindable<Value>: DynamicProperty {
    public var wrappedValue: Value { fatalError() }
    public var projectedValue: Bindable<Value> { self }
    public init(_ v: Value) {}
    public subscript<Subject>(dynamicMember keyPath: ReferenceWritableKeyPath<Value, Subject>) -> Binding<Subject> {
        Binding(get: { fatalError() }, set: { _ in })
    }
}
@MainActor
public protocol Scene {}
@resultBuilder
@MainActor
public struct SceneBuilder {
    public static func buildBlock<C: Scene>(_ c: C) -> C { c }
}
@MainActor
public protocol App {
    associatedtype Body: Scene
    @SceneBuilder var body: Body { get }
}
public extension App {
    static func main() {}
}
public extension App where Body == EmptyScene {
    var body: EmptyScene { EmptyScene() }
}
@MainActor
public struct EmptyScene: Scene { public init() {} }
@MainActor
public struct WindowGroup<Content: View>: Scene {
    public init(@ViewBuilder content: () -> Content) {}
}

// ── 视图修饰符 ──
extension View {
    public func padding(_ edges: Edge.Set = .all, _ length: Double? = nil) -> some View { self }
    public func padding(_ length: Double) -> some View { self }
    public func padding(_ insets: EdgeInsets) -> some View { self }
    public func frame(width: Double? = nil, height: Double? = nil, alignment: Alignment = .center) -> some View { self }
    public func frame(minWidth: Double? = nil, idealWidth: Double? = nil, maxWidth: Double? = nil, minHeight: Double? = nil, idealHeight: Double? = nil, maxHeight: Double? = nil, alignment: Alignment = .center) -> some View { self }
    public func background<S: ShapeStyle>(_ style: S, in shape: some Shape, fillStyle: FillStyle = FillStyle()) -> some View { self }
    public func background<V: View>(@ViewBuilder _ content: () -> V) -> some View { self }
    public func background<V: View>(alignment: Alignment = .center, @ViewBuilder _ content: () -> V) -> some View { self }
    public func background(_ color: Color) -> some View { self }
    public func foregroundStyle<S: ShapeStyle>(_ style: S) -> some View { self }
    public func foregroundColor(_ color: Color?) -> some View { self }
    public func tint(_ color: Color?) -> some View { self }
    public func overlay<V: View>(@ViewBuilder _ content: () -> V) -> some View { self }
    public func overlay<V: View>(alignment: Alignment = .center, @ViewBuilder _ content: () -> V) -> some View { self }
    public func overlay<S: ShapeStyle>(_ style: S, in shape: some Shape) -> some View { self }
    public func overlay<S: ShapeStyle>(_ style: S) -> some View { self }
    public func clipShape<S: Shape>(_ shape: S, style: FillStyle = FillStyle()) -> some View { self }
    public func cornerRadius(_ r: Double, antialiased: Bool = true) -> some View { self }
    public func shadow(color: Color = .black, radius: Double, x: Double = 0, y: Double = 0) -> some View { self }
    public func opacity(_ o: Double) -> some View { self }
    public func scaleEffect(_ s: Double) -> some View { self }
    public func scaleEffect(x: Double = 1, y: Double = 1, anchor: UnitPoint = .center) -> some View { self }
    public func rotationEffect(_ a: Angle, anchor: UnitPoint = .center) -> some View { self }
    public func offset(x: Double = 0, y: Double = 0) -> some View { self }
    public func offset(_ p: CGPoint) -> some View { self }
    public func animation<V: Equatable>(_ animation: Animation?, value: V) -> some View { self }
    public func transition(_ t: AnyTransition) -> some View { self }
    public func onAppear(perform action: (() -> Void)? = nil) -> some View { self }
    public func onDisappear(perform action: (() -> Void)? = nil) -> some View { self }
    public func onChange<V: Equatable>(of value: V, perform action: @escaping (V) -> Void) -> some View { self }
    /// iOS 17+：新旧值双参数形式
    public func onChange<V: Equatable>(of value: V, initial: Bool = false, _ action: @escaping (V, V) -> Void) -> some View { self }
    public func onChange<V: Equatable>(of value: V, initial: Bool, perform action: @escaping (V) -> Void) -> some View { self }
    public func task(_ action: @escaping () async -> Void) -> some View { self }
    public func refreshable(action: @escaping () async -> Void) -> some View { self }
    public func disabled(_ b: Bool) -> some View { self }
    public func hidden() -> some View { self }
    public func fixedSize() -> some View { self }
    public func fixedSize(horizontal: Bool, vertical: Bool) -> some View { self }
    public func gridCellUnsizedAxes(_ axes: Axis.Set) -> some View { self }
    public func lineLimit(_ n: Int?) -> some View { self }
    public func minimumScaleFactor(_ f: Double) -> some View { self }
    public func font(_ f: Font?) -> some View { self }
    public func fontWeight(_ w: Font.Weight?) -> some View { self }
    public func multilineTextAlignment(_ a: TextAlignment) -> some View { self }
    public func textCase(_ c: TextCase?) -> some View { self }
    public func monospacedDigit() -> some View { self }
    public func labelStyle<S: LabelStyle>(_ s: S) -> some View { self }
    public func buttonStyle<S>(_ s: S) -> some View { self }
    public func listStyle<S>(_ s: S) -> some View { self }
    public func scrollIndicators(_ v: ScrollIndicatorVisibility) -> some View { self }
    public func contentShape<S: Shape>(_ shape: S) -> some View { self }
    public func focused(_ condition: FocusState<Bool>.Binding) -> some View { self }
    public func gesture<T: Gesture>(_ g: T) -> some View { self }
    public func simultaneousGesture<T: Gesture>(_ g: T) -> some View { self }
    public func scrollDisabled(_ b: Bool) -> some View { self }
    public func layoutPriority(_ v: Double) -> some View { self }
    public func zIndex(_ v: Double) -> some View { self }
    public func id<V: Hashable>(_ v: V) -> some View { self }
    public func equatable() -> some View { self }
    public func aspectRatio(_ r: Double?, contentMode: ContentMode) -> some View { self }
}

@MainActor
public enum Edge: Sendable {
    case top, bottom, leading, trailing
    public struct Set: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let top = Set(rawValue: 1)
        public static let bottom = Set(rawValue: 2)
        public static let leading = Set(rawValue: 4)
        public static let trailing = Set(rawValue: 8)
        public static let horizontal = Set(rawValue: 12)
        public static let vertical = Set(rawValue: 3)
        public static let all = Set(rawValue: 15)
    }
}
nonisolated public enum ContentMode: Sendable { case fit, fill }
nonisolated public enum ScrollIndicatorVisibility: Sendable { case automatic, visible, hidden, never }
nonisolated public struct FillStyle: Sendable { public init(eoFill: Bool = false, antialiased: Bool = true) {} }

// ── 动画 ──
nonisolated public struct Animation: Sendable {
    public static let `default` = Animation()
    public static let linear = Animation()
    public static let easeIn = Animation()
    public static let easeOut = Animation()
    public static let easeInOut = Animation()
    public static let spring = Animation()
    public static func linear(duration: Double) -> Animation { Animation() }
    public static func easeIn(duration: Double) -> Animation { Animation() }
    public static func easeOut(duration: Double) -> Animation { Animation() }
    public static func easeInOut(duration: Double) -> Animation { Animation() }
    public static func spring(response: Double = 0.55, dampingFraction: Double = 0.825, blendDuration: Double = 0) -> Animation { Animation() }
    public static func spring(duration: Double, bounce: Double = 0.0, blendDuration: Double = 0) -> Animation { Animation() }
    public static func interpolatingSpring(duration: Double, extraBounce: Double = 0, initialVelocity: Double = 0) -> Animation { Animation() }
    public func delay(_ d: Double) -> Animation { self }
    public func repeatCount(_ c: Int, autoreverses: Bool = true) -> Animation { self }
    public func repeatForever(autoreverses: Bool = true) -> Animation { self }
    public func speed(_ s: Double) -> Animation { self }
}
nonisolated public struct AnyTransition: Sendable {
    public static let opacity = AnyTransition()
    public static let identity = AnyTransition()
    public static let scale = AnyTransition()
    public static func scale(scale: Double, anchor: UnitPoint = .center) -> AnyTransition { AnyTransition() }
    public static func move(edge: Edge) -> AnyTransition { AnyTransition() }
    public static func offset(x: Double = 0, y: Double = 0) -> AnyTransition { AnyTransition() }
    public static func asymmetric(insertion: AnyTransition, removal: AnyTransition) -> AnyTransition { AnyTransition() }
    public func combined(with other: AnyTransition) -> AnyTransition { self }
    public func animation(_ a: Animation?) -> AnyTransition { self }
}

// ── 手势 ──
@MainActor
public protocol Gesture {}
@MainActor
public struct TapGesture: Gesture {
    public init(count: Int = 1) {}
    public func onEnded(_ a: @escaping () -> Void) -> some Gesture { TapGesture() }
}
@MainActor
public struct LongPressGesture: Gesture {
    public init(minimumDuration: Double = 0.5, maximumDistance: Double = 10) {}
    public func onEnded(_ a: @escaping (Bool) -> Void) -> some Gesture { TapGesture() }
}
@MainActor
public struct DragGesture: Gesture {
    public init(minimumDistance: Double = 10, coordinateSpace: CoordinateSpace = .local) {}
    public func onChanged(_ a: @escaping (Value) -> Void) -> some Gesture { TapGesture() }
    public func onEnded(_ a: @escaping (Value) -> Void) -> some Gesture { TapGesture() }
    public struct Value { public var translation: CGSize = .zero; public var location: CGPoint = .zero; public init() {} }
}
@MainActor
public struct SimultaneousGesture<A: Gesture, B: Gesture>: Gesture {}

// ── 命名空间 / Observable ──
@MainActor
public struct ObservableMacroPlaceholder {}

// ── window / safe area ──
@MainActor
public enum SafeAreaRegions: Sendable { case container, keyboard, all }
extension View {
    public func safeAreaPadding(_ edges: Edge.Set = .all, _ length: Double? = nil) -> some View { self }
    public func safeAreaInset<V: View>(edge: VerticalEdge, spacing: Double = 0, @ViewBuilder content: () -> V) -> some View { self }
    public func ignoresSafeArea(_ regions: SafeAreaRegions = .all, edges: Edge.Set = .all) -> some View { self }
}
@MainActor
public enum VerticalEdge: Sendable { case top, bottom }

// ── 玻璃效果（iOS 26 原生 API，按官方签名声明）──
nonisolated public struct Glass: Sendable {
    public init() {}
    public static let regular: Glass = Glass()
    public static let clear: Glass = Glass()
    public func tint(_ color: Color?) -> Glass { self }
    public func interactive(_ isEnabled: Bool = true) -> Glass { self }
}
nonisolated public struct DefaultGlassEffectShape: Shape { public init() {} }
@MainActor
public struct RectShape: Shape {}
extension Shape where Self == RectShape {
    public static func rect(cornerRadius: Double, style: RoundedCornerStyle = .circular) -> RectShape { RectShape() }
}
@MainActor
public struct GlassEffectContainer<Content: View>: View {
    public init(spacing: Double? = nil, @ViewBuilder content: () -> Content) {}
}
nonisolated extension View {
    public func glassEffect(_ glass: Glass = Glass(), in shape: some Shape = DefaultGlassEffectShape()) -> some View { self }
    public func glassEffectID(_ id: (some Hashable & Sendable)?, in namespace: Namespace.ID) -> some View { self }
}

// ── 其他 ──
@MainActor
public struct ToolbarItem<Content: View>: View, ToolbarContent {
    public init(@ViewBuilder content: () -> Content) {}
    public init(placement: ToolbarItemPlacement, @ViewBuilder content: () -> Content) {}
}
@MainActor
public enum ToolbarItemPlacement: Sendable { case automatic, principal, navigationBarLeading, navigationBarTrailing, bottomBar, topBarLeading, topBarTrailing, keyboard }
@MainActor
public enum Visibility: Sendable { case automatic, visible, hidden }
@MainActor
public enum NavigationBarItem: Sendable { case title, backButton, largeTitle }
@MainActor
public struct NavigationStack<Content: View>: View {
    public init(@ViewBuilder content: () -> Content) {}
    public init<D: Hashable>(path: Binding<[D]>, @ViewBuilder content: () -> Content) {}
}
@MainActor
public struct NavigationLink<Label: View, Destination: View>: View {
    public init(destination: Destination, @ViewBuilder label: () -> Label) {}
    public init<D: View>(_ title: String, value: some Hashable) where Label == Text, Destination == D {}
    public func navigationDestination<V: View>(isPresented: Binding<Bool>, @ViewBuilder destination: () -> V) -> some View { self }
}
extension View {
    public func navigationTitle(_ title: String) -> some View { self }
    public func navigationBarTitleDisplayMode(_ mode: NavigationBarItemTitleDisplayMode) -> some View { self }
    public func navigationDestination<V: View>(for type: any Hashable.Type, @ViewBuilder destination: @escaping (any Hashable) -> V) -> some View { self }
    public func sheet<V: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> V) -> some View { self }
    public func sheet<Item: Identifiable, V: View>(item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> V) -> some View { self }
    public func alert(_ title: String, isPresented: Binding<Bool>, @ViewBuilder actions: () -> some View) -> some View { self }
    public func alert<A: View>(_ title: String, isPresented: Binding<Bool>, @ViewBuilder actions: () -> A, @ViewBuilder message: () -> some View) -> some View { self }
    public func toolbar<T: ToolbarContent>(@ToolbarContentBuilder content: () -> T) -> some View { self }
    public func toolbar(_ visibility: Visibility, for bars: ToolbarPlacement...) -> some View { self }
    public func toolbarBackground<S: ShapeStyle>(_ style: S, for bars: ToolbarPlacement...) -> some View { self }
    public func toolbarBackground(_ v: Visibility, for bars: ToolbarPlacement...) -> some View { self }
    public func textFieldStyle<S>(_ s: S) -> some View { self }
    public func keyboardType(_ t: KeyboardType) -> some View { self }
    public func textInputAutocapitalization(_ t: TextInputAutocapitalization?) -> some View { self }
    public func autocorrectionDisabled(_ disabled: Bool = true) -> some View { self }
    public func textContentType(_ t: UITextContentType?) -> some View { self }
    public func onSubmit(of fields: SubmitTriggers = .text, _ action: @escaping () -> Void) -> some View { self }
    public func autoscalingFont() -> some View { self }
    public func presentedWindowStyle() -> some View { self }
}
@MainActor
public enum NavigationBarItemTitleDisplayMode: Sendable { case automatic, inline, large }
@MainActor
public enum ToolbarPlacement: Sendable { case navigationBar, tabBar, bottomBar, automatic }
@MainActor
public protocol ToolbarContent {}
@MainActor
public struct ToolbarItemGroup<Content: View>: ToolbarContent { public init(@ViewBuilder content: () -> Content) {} }
@MainActor
public struct ToolbarItemContent: ToolbarContent { public init(placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> some View) {} }
@MainActor
public struct ToolbarSpacer: ToolbarContent { public init() {} }
@resultBuilder public struct ToolbarContentBuilder {
    public static func buildBlock<C: ToolbarContent>(_ c: C) -> C { c }
    public static func buildBlock<C0: ToolbarContent, C1: ToolbarContent>(_ c0: C0, _ c1: C1) -> some ToolbarContent { c0 }
    public static func buildBlock<C0: ToolbarContent, C1: ToolbarContent, C2: ToolbarContent>(_ c0: C0, _ c1: C1, _ c2: C2) -> some ToolbarContent { c0 }
    public static func buildIf<C: ToolbarContent>(_ c: C?) -> C? { c }
    public static func buildEither<C: ToolbarContent>(first: C) -> C { first }
    public static func buildEither<C: ToolbarContent>(second: C) -> C { second }
}
extension View {

}
@MainActor
public struct TabView<Content: View, Selection: Hashable>: View {
    public init(selection: Binding<Selection>, @ViewBuilder content: () -> Content) {}
}
extension TabView where Selection == Never {
    public init(@ViewBuilder content: () -> Content) {}
}
extension View {
    public func tabItem<V: View>(@ViewBuilder _ label: () -> V) -> some View { self }
    public func tag<V: Hashable>(_ tag: V) -> some View { self }
}
@MainActor
public struct TextField<Label: View>: View {
    public init(_ title: String, text: Binding<String>) where Label == Text {}
    public func textFieldStyle<S>(_ s: S) -> TextField { self }
}
@MainActor
public enum KeyboardType: Sendable { case `default`, numberPad, decimalPad, asciiCapable, URL, emailAddress }
@MainActor public enum TextInputAutocapitalization: Sendable { case never, words, sentences, characters }
@MainActor public struct UITextContentType: RawRepresentable, Sendable, Hashable {
    public let rawValue: String
    public nonisolated init(rawValue: String) { self.rawValue = rawValue }
    nonisolated public static let oneTimeCode = UITextContentType(rawValue: "oneTimeCode")
    nonisolated public static let URL = UITextContentType(rawValue: "URL")
    nonisolated public static let emailAddress = UITextContentType(rawValue: "emailAddress")
    nonisolated public static let telephoneNumber = UITextContentType(rawValue: "telephoneNumber")
}
public struct SubmitTriggers: OptionSet, Sendable { public let rawValue: Int; public init(rawValue: Int) { self.rawValue = rawValue }; public static let text = SubmitTriggers(rawValue: 1) }
@MainActor
public struct Slider<Value: BinaryFloatingPoint, ValueLabel: View>: View {
    public init(value: Binding<Value>, in bounds: ClosedRange<Value>, step: Value.Stride = 1, onEditingChanged: @escaping (Bool) -> Void = { _ in }) where ValueLabel == EmptyView {}
    public var body: some View { EmptyView() }
}
@MainActor
public struct SecureField<Label: View>: View {
    public init(_ title: String, text: Binding<String>) where Label == Text {}
}
@MainActor
public protocol ViewModifier {
    associatedtype Content: View
    associatedtype Body: View
    @ViewBuilder func body(content: Self.Content) -> Self.Body
}
@MainActor
public struct MatchGeometryEffect: ViewModifier {
    public typealias Content = EmptyView
    public typealias Body = EmptyView
    public init() {}
    public func body(content: EmptyView) -> EmptyView { EmptyView() }
}
@MainActor
public struct _MatchedGeometryModifier: ViewModifier {
    public typealias Content = EmptyView
    public typealias Body = EmptyView
    public init() {}
    public func body(content: EmptyView) -> EmptyView { EmptyView() }
}

extension View {
    public func modifier<M: ViewModifier>(_ m: M) -> some View { self }
}
@MainActor
public protocol PreferenceKey {
    associatedtype Value
    static var defaultValue: Value { get }
    static func reduce(value: inout Value, nextValue: () -> Value)
}

// @Observable / @MainActor 在 Linux Swift 上原生可用，无需桩
@MainActor
public struct ObservablePlaceholder {}

// ═══════════════════════════════════════════════════════════
// 补充：ForEach / Menu / ShapeStyle / Shape.fill / Edge
// ═══════════════════════════════════════════════════════════

@MainActor
public protocol ShapeStyle {}
extension Color: ShapeStyle {}
@MainActor
public struct Material: ShapeStyle {
    public static let ultraThin = Material()
    public static let thin = Material()
    public static let regular = Material()
    public static let thick = Material()
    public static let ultraThick = Material()
}
@MainActor
public struct HierarchicalShapeStyle: ShapeStyle {
    public static let primary = HierarchicalShapeStyle()
    public static let secondary = HierarchicalShapeStyle()
    public static let tertiary = HierarchicalShapeStyle()
    public static let quaternary = HierarchicalShapeStyle()
}

@MainActor
public struct AnyShapeStyle: ShapeStyle {
    public init<S: ShapeStyle>(_ style: S) {}
}

extension Shape {
    public func trim(from: Double, to: Double) -> some Shape { self }
    public func fill<S: ShapeStyle>(_ content: S, style: FillStyle = FillStyle()) -> some View { self }
    public func fill<S: ShapeStyle>(_ content: S) -> some View { self }
    public func stroke<S: ShapeStyle>(_ content: S, lineWidth: Double = 1) -> some View { self }
    public func stroke<S: ShapeStyle>(_ content: S, style: StrokeStyle) -> some View { self }
    public func strokeBorder<S: ShapeStyle>(_ content: S, lineWidth: Double = 1) -> some View { self }
}

// 简写样式成员（对齐 SwiftUI 的 ShapeStyle 条件扩展；协议扩展只能用计算属性）
extension ShapeStyle where Self == Color {
    public static var white: Color { .white }
    public static var black: Color { .black }
    public static var clear: Color { .clear }
}
extension ShapeStyle where Self == HierarchicalShapeStyle {
    public static var primary: HierarchicalShapeStyle { .primary }
    public static var secondary: HierarchicalShapeStyle { .secondary }
    public static var tertiary: HierarchicalShapeStyle { .tertiary }
}
@MainActor
public struct ForEach<Data: RandomAccessCollection, ID: Hashable, Content: View>: View {
    public init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) where Data.Element: Identifiable, ID == Data.Element.ID {}
    public init(_ data: Data, id: KeyPath<Data.Element, ID>, @ViewBuilder content: @escaping (Data.Element) -> Content) {}
    public init<C: RandomAccessCollection>(_ data: C, id: KeyPath<C.Element, ID>, @ViewBuilder content: @escaping (C.Element) -> Content) where C.Element == Data.Element {}
}

/// UTType 桩
@MainActor
public struct UTType: Sendable, Hashable {
    public var identifier: String
    public static let commaSeparatedText = UTType(identifier: "public.comma-separated-values-text")
    public static let plainText = UTType(identifier: "public.plain-text")
    public static let spreadsheet = UTType(identifier: "public.spreadsheet")
    public static let json = UTType(identifier: "public.json")
    public static let data = UTType(identifier: "public.data")
}

// ═══════════════════════════════════════════════════════════
// Swift Charts 最小桩
// ═══════════════════════════════════════════════════════════
public struct PlottableValue<T> {
    public static func value(_ label: String, _ value: T) -> PlottableValue<T> { PlottableValue<T>() }
}

@MainActor
public protocol ChartContent {}
public struct AnyChartContent: ChartContent {
    public init() {}
    public init<C: ChartContent>(_ content: C) {}
}
@resultBuilder
@MainActor
public struct ChartContentBuilder {
    public static func buildBlock<C: ChartContent>(_ c: C) -> C { c }
    public static func buildBlock<C0: ChartContent, C1: ChartContent>(_ c0: C0, _ c1: C1) -> some ChartContent { AnyChartContent() }
    public static func buildBlock<C0: ChartContent, C1: ChartContent, C2: ChartContent>(_ c0: C0, _ c1: C1, _ c2: C2) -> some ChartContent { AnyChartContent() }
    public static func buildBlock<C0: ChartContent, C1: ChartContent, C2: ChartContent, C3: ChartContent>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3) -> some ChartContent { AnyChartContent() }
    public static func buildBlock<C0: ChartContent, C1: ChartContent, C2: ChartContent, C3: ChartContent, C4: ChartContent>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4) -> some ChartContent { AnyChartContent() }
    public static func buildOptional<C: ChartContent>(_ content: C?) -> some ChartContent { AnyChartContent() }
    public static func buildEither<T: ChartContent, F: ChartContent>(first content: T) -> some ChartContent { AnyChartContent() }
    public static func buildEither<T: ChartContent, F: ChartContent>(second content: F) -> some ChartContent { AnyChartContent() }
}

@MainActor
public struct BarMark: ChartContent {
    public init(x: PlottableValue<some Any>, y: PlottableValue<some Any>) {}
    public func foregroundStyle<S>(_ style: S) -> BarMark { self }
    public func cornerRadius(_ r: Double) -> BarMark { self }
    public func annotation<C: View>(position: AnnotationPosition, alignment: Alignment = .center, spacing: Double? = nil, @ViewBuilder content: () -> C) -> BarMark { self }
}

@MainActor
public struct LineMark: ChartContent {
    public init(x: PlottableValue<some Any>, y: PlottableValue<some Any>) {}
    public func lineStyle(_ style: StrokeStyle) -> LineMark { self }
    public func foregroundStyle<S>(_ style: S) -> LineMark { self }
    public func interpolationMethod(_ m: InterpolationMethod) -> LineMark { self }
}

@MainActor
public struct AreaMark: ChartContent {
    public init(x: PlottableValue<some Any>, y: PlottableValue<some Any>) {}
    public init(x: PlottableValue<some Any>, yStart: PlottableValue<some Any>, yEnd: PlottableValue<some Any>) {}
    public func foregroundStyle<S>(_ style: S) -> AreaMark { self }
    public func opacity(_ o: Double) -> AreaMark { self }
    public func interpolationMethod(_ m: InterpolationMethod) -> AreaMark { self }
}

@MainActor
public struct PointMark: ChartContent {
    public init(x: PlottableValue<some Any>, y: PlottableValue<some Any>) {}
}

@MainActor
public enum InterpolationMethod { case linear, monotone, catmullRom, stepStart, stepEnd, stepCenter }

@MainActor
public enum AnnotationPosition { case leading, trailing, top, bottom, center, overlay }

@MainActor
public struct Chart<Data: RandomAccessCollection, Content: ChartContent>: View where Data.Element: Identifiable {
    public init(_ data: Data, @ChartContentBuilder content: @escaping (Data.Element) -> Content) {}
}

@MainActor
public protocol PickerStyle {}
@MainActor
public struct SegmentedPickerStyle: PickerStyle { public init() {} }
@MainActor
public struct MenuPickerStyle: PickerStyle { public init() {} }
extension PickerStyle where Self == SegmentedPickerStyle {
    public static var segmented: SegmentedPickerStyle { SegmentedPickerStyle() }
}
extension PickerStyle where Self == MenuPickerStyle {
    public static var menu: MenuPickerStyle { MenuPickerStyle() }
}
@MainActor
public struct Picker<Label: View, SelectionValue: Hashable, Content: View>: View {
    public init(_ titleKey: String, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) where Label == Text {}
    public var body: some View { EmptyView() }
}

@MainActor
public enum AxisMarkPosition { case leading, trailing, top, bottom }
@MainActor
public enum AxisMarksValues { case automatic(desiredCount: Int) }
@MainActor
public struct AxisMarks: ChartContent, Equatable {
    public static let hidden = AxisMarks()
    public static let automatic = AxisMarks()
    public init() {}
    /// 用 @ViewBuilder 而非自定义 builder，并让闭包返回 EmptyView：
    /// 这在语义上等价（桩不产生真实内容），但避免了 Swift 6.1 在
    /// 自定义 result builder + 嵌套尾闭包上的约束求解器崩溃。
    public init<V: View>(position: AxisMarkPosition = .leading,
                         values: AxisMarksValues = .automatic(desiredCount: 4),
                         @ViewBuilder content: (AxisValueLabel) -> V) {}
    public init<V: View>(values: AxisMarksValues = .automatic(desiredCount: 4),
                         @ViewBuilder content: (AxisValueLabel) -> V) {}
}
@MainActor
public struct AxisValueLabel: View, ChartContent {
    public init() {}
    public func font(_ f: Font) -> AxisValueLabel { self }
    public func foregroundStyle<S>(_ s: S) -> AxisValueLabel { self }
}
@MainActor
public struct AxisGridLine: View, ChartContent {
    public init() {}
    public func foregroundStyle<S>(_ s: S) -> AxisGridLine { self }
}
@resultBuilder
@MainActor
public struct AxisMarkBuilder {
    public static func buildBlock() -> AnyChartContent { AnyChartContent(AxisMarks()) }
    public static func buildBlock<C: ChartContent>(_ c: C) -> AnyChartContent { AnyChartContent(AxisMarks()) }
    public static func buildBlock<C0: View, C1: View>(_ c0: C0, _ c1: C1) -> AnyChartContent { AnyChartContent(AxisMarks()) }
    public static func buildBlock<C0: View, C1: View, C2: View>(_ c0: C0, _ c1: C1, _ c2: C2) -> AnyChartContent { AnyChartContent(AxisMarks()) }
    public static func buildBlock<C0: View, C1: View, C2: View, C3: View>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3) -> AnyChartContent { AnyChartContent(AxisMarks()) }
    public static func buildBlock<C0: View, C1: View, C2: View, C3: View, C4: View>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4) -> AnyChartContent { AnyChartContent(AxisMarks()) }
    public static func buildEither<T: View, F: View>(first c: T) -> _ConditionalContent<T, F> { _ConditionalContent() }
    public static func buildEither<T: View, F: View>(second c: F) -> _ConditionalContent<T, F> { _ConditionalContent() }
    public static func buildOptional<C: View>(_ c: C?) -> AnyChartContent { AnyChartContent(AxisMarks()) }
    public static func buildExpression<C: ChartContent>(_ c: C) -> AnyChartContent { AnyChartContent(AxisMarks()) }
    public static func buildExpression<V: View>(_ v: V) -> AnyChartContent { AnyChartContent(AxisMarks()) }
}
extension View {
    public func chartXAxis(_ v: AxisMarks) -> some View { self }
    public func chartYAxis(_ v: AxisMarks) -> some View { self }
    public func chartXAxis(@AxisMarkBuilder _ content: () -> AnyChartContent) -> some View { self }
    public func chartYAxis(@AxisMarkBuilder _ content: () -> AnyChartContent) -> some View { self }
    public func chartYScale(domain: ClosedRange<Double>) -> some View { self }
    public func chartXScale(domain: ClosedRange<Double>) -> some View { self }
    public func pickerStyle<S: PickerStyle>(_ style: S) -> some View { self }
}

// ── 补齐：文件导入 / 确认弹窗 / Edge 便捷构造 / 可见性 ──
extension View {
    public func fileImporter(isPresented: Binding<Bool>,
                             allowedContentTypes: [UTType],
                             allowsMultipleSelection: Bool = false,
                             onCompletion: @escaping (Result<[URL], Error>) -> Void) -> some View { self }
    public func fileImporter(isPresented: Binding<Bool>,
                             allowedContentTypes: [UTType],
                             onCompletion: @escaping (Result<URL, Error>) -> Void) -> some View { self }
    public func confirmationDialog<A: View, M: View>(_ title: String,
                                                     isPresented: Binding<Bool>,
                                                     titleVisibility: Visibility = .automatic,
                                                     @ViewBuilder actions: () -> A,
                                                     @ViewBuilder message: () -> M) -> some View { self }
    public func confirmationDialog<A: View>(_ title: String,
                                            isPresented: Binding<Bool>,
                                            titleVisibility: Visibility = .automatic,
                                            @ViewBuilder actions: () -> A) -> some View { self }
}

/// EdgeInsets 的 Edge 构造重载（SwiftUI 中 EdgeInsets 也是 ShapeStyle 的 padding 参数）
extension Double {
    public var top: EdgeInsets { EdgeInsets(top: self) }
}

/// ButtonRole
@MainActor
public struct ButtonRole: Sendable {
    public static let destructive = ButtonRole()
    public static let cancel = ButtonRole()
}
extension Button {
    public init(_ title: String, role: ButtonRole?, action: @escaping () -> Void) where Label == Text {}
    public init(role: ButtonRole?, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {}
}

/// ButtonRole 需同时支持 `.destructive` / `.cancel`（值语义）
extension ButtonRole: Equatable {
    public static func == (l: ButtonRole, r: ButtonRole) -> Bool { true }
}
extension Text {
    public func fontWeight(_ w: Font.Weight) -> Text { self }
}

// ═══════════════════════════════════════════════════════════
// 结果构建器 ViewBuilder（对标 Apple 真实实现）
// 关键：buildEither 的第一个泛型参数与第二个必须不同，
//      否则两个分支会被折叠成同一类型，破坏类型推断。
// ═══════════════════════════════════════════════════════════
@MainActor
public struct _ConditionalContent<TrueContent: View, FalseContent: View>: View {
    public init() {}
}

@resultBuilder
@MainActor
public struct ViewBuilder {
    public static func buildBlock() -> EmptyView { EmptyView() }
    public static func buildBlock<Content: View>(_ content: Content) -> Content { content }

    public static func buildBlock<C0: View, C1: View>(_ c0: C0, _ c1: C1) -> TupleView<(C0, C1)> { TupleView() }
    public static func buildBlock<C0: View, C1: View, C2: View>(_ c0: C0, _ c1: C1, _ c2: C2) -> TupleView<(C0, C1, C2)> { TupleView() }
    public static func buildBlock<C0: View, C1: View, C2: View, C3: View>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3) -> TupleView<(C0, C1, C2, C3)> { TupleView() }
    public static func buildBlock<C0: View, C1: View, C2: View, C3: View, C4: View>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4) -> TupleView<(C0, C1, C2, C3, C4)> { TupleView() }
    public static func buildBlock<C0: View, C1: View, C2: View, C3: View, C4: View, C5: View>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5) -> TupleView<(C0, C1, C2, C3, C4, C5)> { TupleView() }
    public static func buildBlock<C0: View, C1: View, C2: View, C3: View, C4: View, C5: View, C6: View>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5, _ c6: C6) -> TupleView<(C0, C1, C2, C3, C4, C5, C6)> { TupleView() }
    public static func buildBlock<C0: View, C1: View, C2: View, C3: View, C4: View, C5: View, C6: View, C7: View>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5, _ c6: C6, _ c7: C7) -> TupleView<(C0, C1, C2, C3, C4, C5, C6, C7)> { TupleView() }

    public static func buildIf<Content: View>(_ content: Content?) -> Content? { content }
    public static func buildIf<Content>(_ content: Content) -> Content { content }

    /// 关键：两个分支类型不同，保留各自的真实类型
    public static func buildEither<T: View, F: View>(first content: T) -> _ConditionalContent<T, F> { _ConditionalContent() }
    public static func buildEither<T: View, F: View>(second content: F) -> _ConditionalContent<T, F> { _ConditionalContent() }

    public static func buildOptional<Content: View>(_ content: Content?) -> _ConditionalContent<Content, EmptyView> { _ConditionalContent() }
    public static func buildLimitedAvailability<Content: View>(_ content: Content) -> AnyView { AnyView(content) }
}

@MainActor
public struct TupleView<T>: View { public init() {} }

// ═══════════════════════════════════════════════════════════
// 补充：withAnimation / Animation.spring / environment / accessibility
// ═══════════════════════════════════════════════════════════
@MainActor
public func withAnimation<Result>(_ animation: Animation? = .default, _ body: () throws -> Result) rethrows -> Result {
    try body()
}
@MainActor
public func withAnimation<Result>(_ animation: Animation?, completionCriteria: Any? = nil, _ body: () throws -> Result) rethrows -> Result {
    try body()
}

extension View {
    /// 注入 Observable 对象到环境（iOS 17+ 的 .environment(_:) 形式）
    public func environment<T>(_ object: T?) -> some View { self }
    public func environment<T>(_ object: T) -> some View { self }
    /// 注入 EnvironmentKey 值：.environment(\.key, value)
    public func environment<V>(_ keyPath: WritableKeyPath<EnvironmentValues, V>, _ value: V) -> some View { self }
    public func accessibilityElement(children: AccessibilityChildBehavior = .ignore) -> some View { self }
    public func accessibilityLabel(_ label: String) -> some View { self }
    public func accessibilityValue(_ value: String) -> some View { self }
    public func accessibilityAddTraits(_ traits: AccessibilityTraits) -> some View { self }
}
nonisolated public enum AccessibilityChildBehavior: Sendable { case ignore, contain, combine }
nonisolated public struct AccessibilityTraits: OptionSet, Sendable, ExpressibleByArrayLiteral {
    public typealias ArrayLiteralElement = AccessibilityTraits
    public init(arrayLiteral elements: AccessibilityTraits...) { self = AccessibilityTraits(rawValue: 0) }
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let isSelected = AccessibilityTraits(rawValue: 1)
    public static let isButton = AccessibilityTraits(rawValue: 2)
}

// ═══════════════════════════════════════════════════════════
// 补充：@Environment(Object.self) / controlSize / tint
// ═══════════════════════════════════════════════════════════
public struct EnvironmentObjectKey: Sendable { public init() {} }

public enum ControlSize: Sendable { case mini, small, regular, large, extraLarge }

extension View {
    public func controlSize(_ size: ControlSize) -> some View { self }
    public func tint<S: ShapeStyle>(_ tint: S) -> some View { self }
}

// ═══════════════════════════════════════════════════════════
// 补充：胶囊形状 / 命中测试 / 模糊 / 按钮样式
// ═══════════════════════════════════════════════════════════
extension Shape where Self == Capsule {
    public static var capsule: Capsule { Capsule() }
}

extension Shape where Self == Circle {
    public static var circle: Circle { Circle() }
}

extension View {
    public func allowsHitTesting(_ enabled: Bool) -> some View { self }
    public func blur(radius: Double, opaque: Bool = false) -> some View { self }
}
