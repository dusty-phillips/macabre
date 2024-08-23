import compiler/python
import glance
import gleam/list
import gleam/option

pub fn transform_custom_type(
  custom_type: glance.CustomType,
) -> python.CustomType {
  python.CustomType(
    name: custom_type.name,
    parameters: custom_type.parameters,
    variants: list.map(custom_type.variants, transform_type_variant),
  )
}

fn transform_type_variant(variant: glance.Variant) -> python.Variant {
  python.Variant(
    name: variant.name,
    fields: list.map(variant.fields, transform_variant_field),
  )
}

fn transform_variant_field(
  field: glance.Field(glance.Type),
) -> python.Field(python.Type) {
  case field {
    glance.Field(label: option.None, item: item) ->
      python.UnlabelledField(transform_type(item))
    glance.Field(label: option.Some(label), item: item) ->
      python.LabelledField(label, transform_type(item))
  }
}

fn transform_type(type_: glance.Type) -> python.Type {
  case type_ {
    glance.NamedType(name, module, parameters) ->
      python.NamedType(name, module, list.map(parameters, transform_type))

    glance.TupleType(elements) ->
      python.TupleType(list.map(elements, transform_type))

    glance.FunctionType(..) ->
      todo as "Not able to transform function types yet"

    glance.VariableType(name) -> {
      python.GenericType(name)
    }

    glance.HoleType(..) -> todo as "I don't even know what a hole type is"
  }
}
