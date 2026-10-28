# TODO: source_doc should only be a string once we remove application/html+erlang.
defmodule ExDoc.ModuleNode do
  @moduledoc """
  Represents a module.
  """

  defstruct id: nil,
            title: nil,
            nested_context: nil,
            nested_title: nil,
            module: nil,
            group: nil,
            deprecated: nil,
            doc: nil,
            source_doc: nil,
            source_format: nil,
            moduledoc_line: nil,
            moduledoc_file: nil,
            source_path: nil,
            source_url: nil,
            docs_groups: [],
            typespecs: [],
            type: nil,
            language: nil,
            annotations: [],
            metadata: nil

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          nested_context: String.t() | nil,
          nested_title: String.t() | nil,
          module: module(),
          group: atom() | nil,
          deprecated: String.t() | nil,
          doc: ExDoc.DocAST.t() | nil,
          source_doc: term() | nil,
          source_format: String.t() | nil,
          moduledoc_line: non_neg_integer(),
          moduledoc_file: String.t(),
          source_path: String.t() | nil,
          source_url: String.t() | nil,
          docs_groups: [ExDoc.DocGroupNode.t()],
          typespecs: [ExDoc.DocNode.t()],
          type: atom(),
          language: module(),
          annotations: [atom()],
          metadata: map()
        }
end

defmodule ExDoc.DocNode do
  @moduledoc """
  Represents a function, macro, callback, or type.
  """

  defstruct id: nil,
            name: nil,
            arity: 0,
            defaults: [],
            deprecated: nil,
            doc: nil,
            source_doc: nil,
            type: nil,
            signature: nil,
            source_specs: [],
            specs: [],
            annotations: [],
            group: nil,
            doc_line: nil,
            doc_file: nil,
            source_url: nil

  @type annotation :: String.t()
  @type function_default :: {name :: atom(), arity :: non_neg_integer()}
  @type spec_ast :: term()

  @type t :: %__MODULE__{
          id: String.t(),
          name: atom(),
          arity: non_neg_integer(),
          defaults: [function_default()],
          deprecated: String.t() | nil,
          doc: ExDoc.DocAST.t() | nil,
          source_doc: term() | nil,
          type: atom(),
          signature: String.t(),
          source_specs: [spec_ast()],
          specs: [String.t()],
          annotations: [annotation()],
          group: String.t() | nil,
          doc_file: String.t(),
          doc_line: non_neg_integer(),
          source_url: String.t() | nil
        }
end

defmodule ExDoc.DocGroupNode do
  @moduledoc """
  Represents a group of functions, macros, callbacks, or types.
  """
  defstruct title: nil, description: nil, doc: nil, docs: []

  @type t :: %__MODULE__{
          title: String.t() | atom(),
          description: String.t() | nil,
          doc: ExDoc.DocAST.t() | nil,
          docs: [ExDoc.DocNode.t()]
        }
end

defmodule ExDoc.ExtraNode do
  @moduledoc """
  Represents an extra page.
  """

  defstruct id: nil,
            title: nil,
            title_doc: nil,
            group: nil,
            type: nil,
            doc: nil,
            source_doc: nil,
            source_path: nil,
            source_url: nil,
            search_data: nil

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          title_doc: ExDoc.DocAST.t() | String.t(),
          group: atom() | nil,
          type: atom(),
          doc: ExDoc.DocAST.t() | nil,
          source_doc: String.t(),
          source_path: String.t(),
          source_url: String.t(),
          search_data: [map()] | nil
        }
end

defmodule ExDoc.URLNode do
  @moduledoc """
  Represents an extra URL.
  """

  defstruct id: nil,
            title: nil,
            group: nil,
            url: nil

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          group: atom() | nil,
          url: String.t()
        }
end
