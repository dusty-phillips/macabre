import compiler/python
import glance
import gleam/list

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
  field: glance.VariantField,
) -> python.Field(python.Type) {
  case field {
    glance.UnlabelledVariantField(item) ->
      python.UnlabelledField(transform_type(item))
    glance.LabelledVariantField(item, label) ->
      python.LabelledField(label, transform_type(item))
  }
}

fn transform_type(type_: glance.Type) -> python.Type {
  case type_ {
    glance.NamedType(_, name, module, parameters) ->
      python.NamedType(name, module, list.map(parameters, transform_type))

    glance.TupleType(_, elements) ->
      python.TupleType(list.map(elements, transform_type))

    glance.FunctionType(_, parameters, return_type) ->
      python.FunctionType(
        list.map(parameters, transform_type),
        transform_type(return_type),
      )

    glance.VariableType(_, name) -> {
      python.GenericType(name)
    }

    glance.HoleType(_, name) -> {
      python.GenericType(name)
    }
  }
}
