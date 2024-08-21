import gleam/option

pub type Context(a) {
  Context(imports: List(Import), item: a)
}

pub type Import {
  UnqualifiedImport(module: String, name: String, alias: option.Option(String))
}

pub const dataclass_import = UnqualifiedImport(
  "dataclasses",
  "dataclass",
  option.None,
)

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

pub type Expression {
  String(String)
  Number(String)
  Bool(String)
  Variable(String)
  Tuple(List(Expression))
  Negate(Expression)
  Not(Expression)
  Panic(Expression)
  Todo(Expression)
  List(elements: List(Expression))
  ListWithRest(elements: List(Expression), rest: Expression)
  TupleIndex(tuple: Expression, index: Int)
  FieldAccess(container: Expression, label: String)
  Call(function: Expression, arguments: List(Field(Expression)))
  RecordUpdate(record: Expression, fields: List(Field(Expression)))
  BinaryOperator(name: BinaryOperator, left: Expression, right: Expression)
}

pub type Statement {
  Expression(Expression)
  Return(Expression)
  SimpleAssignment(name: String, value: Expression)
}

pub type FunctionParameter {
  NameParam(String)
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
  GenericType(name: String)
}

pub type Variant {
  Variant(name: String, fields: List(Field(Type)))
}

pub type CustomType {
  CustomType(name: String, parameters: List(String), variants: List(Variant))
}

pub type Function {
  Function(
    name: String,
    parameters: List(FunctionParameter),
    body: List(Statement),
  )
}

pub type Module {
  Module(
    imports: List(Import),
    functions: List(Function),
    custom_types: List(CustomType),
  )
}

pub fn empty_module() -> Module {
  Module(imports: [], functions: [], custom_types: [])
}
