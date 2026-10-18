import Foundation

/// 着色用的关键字和内置类型名（见 `SyntaxHighlighter`）。SQL 的写小写，比较时不分大小写。
enum Keywords {
    private static func set(_ words: String) -> Set<String> {
        Set(words.split(whereSeparator: \.isWhitespace).map(String.init))
    }

    static let swift = set("""
        associatedtype class deinit enum extension fileprivate func import init inout internal let open operator
        private protocol public rethrows static struct subscript typealias var break case continue default defer do
        else fallthrough for guard if in repeat return switch where while as catch false is nil super self Self throw
        throws true try async await actor some any mutating nonmutating override convenience required lazy weak unowned
        final indirect get set willSet didSet consuming borrowing nonisolated isolated package
        """)

    static let c = set("""
        auto break case const continue default do else enum extern for goto if inline register restrict return
        sizeof static struct switch typedef union volatile while NULL true false
        """)

    static let cTypes = set("""
        char double float int long short signed unsigned void bool size_t ssize_t int8_t int16_t int32_t int64_t
        uint8_t uint16_t uint32_t uint64_t uintptr_t
        """)

    static let objectiveC = set("""
        interface implementation end property synthesize dynamic protocol optional required selector class import
        self super nil Nil YES NO id instancetype nonatomic atomic strong weak copy assign readonly readwrite nullable
        nonnull autoreleasepool try catch finally throw encode
        """)

    static let cpp = set("""
        alignas alignof and asm catch class constexpr const_cast decltype delete explicit export friend mutable
        namespace new noexcept not nullptr operator or override private protected public reinterpret_cast static_assert
        static_cast template this thread_local throw try typeid typename using virtual final concept requires
        co_await co_return co_yield
        """)

    static let csharp = set("""
        abstract as base bool break byte case catch char checked class const continue decimal default delegate do
        double else enum event explicit extern false finally fixed float for foreach goto if implicit in int interface
        internal is lock long namespace new null object operator out override params private protected public readonly
        ref return sbyte sealed short sizeof stackalloc static string struct switch this throw true try typeof uint
        ulong unchecked unsafe ushort using virtual void volatile while var async await get set init record yield
        dynamic nameof when where partial
        """)

    static let java = set("""
        abstract assert boolean break byte case catch char class const continue default do double else enum extends
        final finally float for goto if implements import instanceof int interface long native new package private
        protected public return short static strictfp super switch synchronized this throw throws transient try void
        volatile while true false null var record sealed permits yield
        """)

    static let kotlin = set("""
        as break class continue do else false for fun if in interface is null object package return super this throw
        true try typealias val var when while by catch constructor finally get import init set where abstract
        annotation companion const crossinline data enum expect actual external final infix inline inner internal
        lateinit noinline open operator out override private protected public reified sealed suspend tailrec vararg
        """)

    static let go = set("""
        break case chan const continue default defer else fallthrough for func go goto if import interface map package
        range return select struct switch type var true false nil iota
        """)

    static let goTypes = set("""
        bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16
        uint32 uint64 uintptr any
        """)

    static let rust = set("""
        as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move
        mut pub ref return self Self static struct super trait true type unsafe use where while union
        """)

    static let rustTypes = set("""
        i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str
        """)

    static let javascript = set("""
        await break case catch class const continue debugger default delete do else export extends false finally for
        function if import in instanceof let new null return super switch this throw true try typeof undefined var void
        while with yield async of static get set from as
        """)

    static let typescript = set("""
        abstract asserts declare enum implements infer interface is keyof namespace private protected public readonly
        type unique satisfies override
        """)

    static let typescriptTypes = set("any bigint boolean never number object string symbol unknown void")

    static let python = set("""
        False None True and as assert async await break class continue def del elif else except finally for from global
        if import in is lambda nonlocal not or pass raise return try while with yield match case self cls
        """)

    static let pythonTypes = set("int str float bool list dict set tuple bytes object")

    static let ruby = set("""
        BEGIN END alias and begin break case class def defined? do else elsif end ensure false for if in module next nil
        not or redo rescue retry return self super then true undef unless until when while yield require
        require_relative attr_accessor attr_reader attr_writer private protected public lambda proc
        """)

    static let php = set("""
        abstract and array as break callable case catch class clone const continue declare default do echo else elseif
        empty extends final finally fn for foreach function global goto if implements include include_once instanceof
        insteadof interface isset list match namespace new or print private protected public readonly require
        require_once return static switch throw trait try unset use var while xor yield true false null self parent
        """)

    static let shell = set("""
        if then else elif fi case esac for select while until do done in function time return exit export local
        readonly declare typeset unset shift source alias break continue eval exec set trap
        """)

    static let sql = set("""
        select from where insert into values update set delete create table index view drop alter add column primary
        key foreign references not null unique default and or in is like between join left right inner outer full cross
        on as order by group having limit offset distinct union all exists case when then else end with returning
        conflict do nothing begin commit rollback transaction if asc desc true false pragma cascade trigger replace
        """)

    static let sqlTypes = set("""
        integer int text real blob varchar char boolean date timestamp numeric float double bigint serial json jsonb uuid
        """)
}
