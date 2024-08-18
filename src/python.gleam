import gleam/option

pub type Import {
  UnqualifiedImport(module: String, name: String, alias: option.Option(String))
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

pub type Expression {
  String(String)
  Number(String)
  Bool(String)
  Tuple(List(Expression))
  TupleIndex(tuple: Expression, index: Int)
  Call(function_name: String, arguments: List(Expression))
  BinaryOperator(name: BinaryOperator, left: Expression, right: Expression)
}

pub type Statement {
  Expression(Expression)
}

pub type FunctionParameter {
  NameParam(String)
}

pub type Type {
  TodoType
}

pub type Function {
  Function(
    name: String,
    parameters: List(FunctionParameter),
    body: List(Statement),
  )
}

pub type Module {
  Module(imports: List(Import), functions: List(Function))
}

pub fn empty_module() -> Module {
  Module(imports: [], functions: [])
}
