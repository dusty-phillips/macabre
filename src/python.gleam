import gleam/option

pub type Import {
  UnqualifiedImport(module: String, name: String, alias: option.Option(String))
}

pub type Expression {
  String(String)
  Call(function_name: String, arguments: List(Expression))
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
