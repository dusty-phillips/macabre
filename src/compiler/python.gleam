import gleam/option

pub type Context(a) {
  Context(imports: List(Import), item: a)
}

pub type Import {
  UnqualifiedImport(module: String, name: String)
  AliasedUnqualifiedImport(module: String, name: String, alias: String)
  QualifiedImport(module: String)
  AliasedQualifiedImport(module: String, alias: String)
}

pub type BinaryOperator {
  And
  Or
  Equal
  NotEqual
  Add
  Subtract
  Multiply
  Divide
  DivideInt
  LessThan
  LessThanEqual
  GreaterThan
  GreaterThanEqual
  Modulo
}

pub type Constant {
  Constant(
    name: String,
    value: Expression,
    public: Bool,
    docstring: option.Option(String),
    comments: List(String),
  )
}

pub type Expression {
  String(String)
  Number(String)
  Bool(String)
  Nil
  Variable(String)
  ModuleRef(String)
  Tuple(List(Expression))
  Negate(Expression)
  Not(Expression)
  Panic(Expression)
  Todo(Expression)
  Lambda(args: List(Expression), body: Expression)
  List(elements: List(Expression))
  ListWithRest(elements: List(Expression), rest: Expression)
  TupleIndex(tuple: Expression, index: Int)
  FieldAccess(container: Expression, label: String)
  Call(function: Expression, arguments: List(Field(Expression)))
  RecordUpdate(record: Expression, fields: List(Field(Expression)))
  BinaryOperator(name: BinaryOperator, left: Expression, right: Expression)
  Slice(
    container: Expression,
    start: Expression,
    end: option.Option(Expression),
  )
  AssignmentExpression(name: String, value: Expression)
  IsNotNone(expression: Expression)
  BitString(List(BitStringSegment))
  Dict(List(#(String, Expression)))
}

pub type BitStringSegment {
  BitStringSegment(value: Expression, options: List(BitStringSegmentOption))
}

pub type BitStringSegmentOption {
  SizeValueOption(Expression)
  UnitOption(Int)
  FloatOption
  IntOption
  LittleOption
  BigOption
  BitStringOption
  Utf8Option
  Utf16Option
  Utf32Option
  Utf8CodepointOption
  Utf16CodepointOption
  Utf32CodepointOption
  NativeOption
}

pub type Statement {
  Expression(Expression)
  Return(Expression)
  FunctionDef(Function)
  Match(subject: Expression, cases: List(MatchCase))
  SimpleAssignment(name: String, value: Expression)
  MultipleAssignment(names: List(String), value: Expression)
  While(condition: Expression, body: List(Statement))
  If(condition: Expression, body: List(Statement))
}

pub type FunctionParameter {
  NameParam(String)
  DiscardParam(discard_index: Int)
}

pub type Field(t) {
  LabelledField(label: String, item: t)
  UnlabelledField(item: t)
}

pub type Type {
  NamedType(
    name: String,
    module: option.Option(String),
    generic_parameters: List(Type),
  )
  TupleType(elements: List(Type))
  FunctionType(parameters: List(Type), return_type: Type)
  GenericType(name: String)
}

pub type Variant {
  Variant(name: String, fields: List(Field(Type)))
}

pub type CustomType {
  CustomType(
    name: String,
    parameters: List(String),
    variants: List(Variant),
    public: Bool,
    docstring: option.Option(String),
    comments: List(String),
  )
}

pub type MatchCase {
  // Inner List is collecting tuples together, outer list is patterns that get or'd together
  // e.g. 1,2 | 3, 4 becomes [[1,2], [3, 4]]
  MatchCase(
    pattern: Pattern,
    guard: option.Option(Expression),
    body: List(Statement),
  )
}

pub type Pattern {
  PatternWildcard
  PatternInt(value: String)
  PatternFloat(value: String)
  PatternString(value: String)
  PatternVariable(value: String)
  PatternAssignment(pattern: Pattern, name: String)
  PatternTuple(value: List(Pattern))
  PatternList(elems: List(Pattern), rest: option.Option(Pattern))
  PatternAlternate(patterns: List(Pattern))
  PatternConstructor(
    module: option.Option(String),
    constructor: String,
    arguments: List(Field(Pattern)),
  )
}

pub type Function {
  Function(
    name: String,
    parameters: List(FunctionParameter),
    body: List(Statement),
    public: Bool,
    docstring: option.Option(String),
    comments: List(String),
  )
}

pub type Module {
  Module(
    imports: List(Import),
    functions: List(Function),
    custom_types: List(CustomType),
    constants: List(Constant),
    docstring: option.Option(String),
    comments: List(String),
  )
}

pub fn empty_module() -> Module {
  Module(
    imports: [],
    functions: [],
    custom_types: [],
    constants: [],
    docstring: option.None,
    comments: [],
  )
}
