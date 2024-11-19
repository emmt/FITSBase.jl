"""
    FITSHeaders.Cards

A sub-module of the `FITSHeaders` package implementing the methods and properties for FITS
header cards.

"""
module Cards

export FitsCard

using ..FITSHeaders
using ..FITSHeaders:
    CardName,
    CardValue,
    CardComment,
    FitsInteger,
    FitsFloat,
    FitsComplex,
    Undef,
    Undefined
import ..FITSHeaders:
    FitsCardType
using ..FITSHeaders.Parser:
    EMPTY_STRING,
    ByteBuffer,
    check_keyword,
    get_units_part,
    get_unitless_part,
    make_string,
    parse_complex_value,
    parse_float_value,
    parse_integer_value,
    parse_logical_value,
    parse_string_value,
    scan_card
import ..FITSHeaders.Parser:
    is_structural,
    is_comment,
    is_naxis,
    is_end

using Dates, TypeUtils

# Extended union of possible card values. Any of these shall extend the `to_value` method.
const CardValueExt = Union{CardValue,DateTime}

const END_STRING = "END"
const UNDEF_INTEGER = zero(FitsInteger)
const UNDEF_COMPLEX = FitsComplex(NaN,NaN)
const UNDEF_FLOAT = FitsComplex(NaN,0.0)
const UNDEF_STRING = EMPTY_STRING

"""
    card = FitsCard(key => (val, com))

builds a FITS header card associating keyword `key` with value `val` and comment string
`com`. The value `val` may be:

- a boolean to yield a card of type `FITS_LOGICAL`;
- an integer to yield a card of type `FITS_INTEGER`;
- a real to yield a card of type `FITS_FLOAT`;
- a complex to yield a card of type `FITS_COMPLEX`;
- a string to yield a card of type `FITS_STRING`;
- `nothing` to yield a card of type `FITS_COMMENT`;
- `undef` or `missing` to yield a card of type `FITS_UNDEFINED`.

The comment may be omitted for a normal FITS card and the value may be omitted for a
commentary FITS card:

    card = FitsCard(key => val::Number)
    card = FitsCard(key => str::AbstractString)

In the 1st case, the comment is assumed to be empty. In the 2nd case, the string `str` is
assumed to be the card comment if `key` is `"COMMENT"` or `"HISTORY"` and the card value
otherwise.

FITS cards have properties:

    card.type     # type of card: FITS_LOGICAL, FITS_INTEGER, etc.
    card.key      # quick key of card: Fits"BITPIX", Fits"HIERARCH", etc.
    card.name     # name of card
    card.value    # callable object representing the card value
    card.comment  # comment of card
    card.units    # units of card value
    card.unitless # comment of card without the units part if any

As the values of FITS keywords have different types, `card.value` does not yield a Julia
value but a callable object. Called without any argument, this object yields the actual
card value:

    card.value() -> val::Union{Bool,$FitsInteger,$FitsFloat,$FitsComplex,String,Nothing,$Undef}

but such a call is not *type-stable* as indicated by the type assertion with an
`Union{...}` above. For a type-stable result, the card value can be converted to a given
data type `T`:

    card.value(T)
    convert(T, card.value)

both yield the value of `card` converted to type `T`. For readability, `T` may be an
abstract type: `card.value(Integer)` yields the same result as `card.value($FitsInteger)`,
`card.value(Real)` or `card.value(AbstractFloat)` yield the same result as
`card.value($FitsFloat)`, `card.value(Complex)` yields the same result as
`card.value($FitsComplex)`, and `card.value(AbstractString)` yields the same result as
`card.value(String)`.

To make things easier, a few properties are aliases that yield the card value converted to
a specific type:

    card.logical :: Bool       # alias for card.value(Bool)
    card.integer :: $FitsInteger      # alias for card.value(Integer)
    card.float   :: $FitsFloat    # alias for card.value(Real)
    card.complex :: $FitsComplex # alias for card.value(Complex)
    card.string  :: String     # alias for card.value(String)

Conversion is automatically attempted if the actual card value is of a different type,
throwing an error if the conversion is not possible or inexact.

`valtype(card)` yields the type of the value of `card`. `isassigned(card)` yields whether
`card` has a value (that is whether it is neither a commentary card nor a card with an
undefined value).

"""
struct FitsCard
    key::FitsKey
    type::FitsCardType
    value_integer::FitsInteger
    value_complex::FitsComplex
    value_string::String
    name::String
    comment::String
    FitsCard(key::FitsKey, name::AbstractString, val::Bool, com::AbstractString) =
        new(key, FITS_LOGICAL, val, UNDEF_COMPLEX, UNDEF_STRING, name, com)
    FitsCard(key::FitsKey, name::AbstractString, val::Integer, com::AbstractString) =
        new(key, FITS_INTEGER, val, UNDEF_COMPLEX, UNDEF_STRING, name, com)
    FitsCard(key::FitsKey, name::AbstractString, val::Real, com::AbstractString) =
         new(key, FITS_FLOAT, UNDEF_INTEGER, val, UNDEF_STRING, name, com)
    FitsCard(key::FitsKey, name::AbstractString, val::Complex, com::AbstractString) =
         new(key, FITS_COMPLEX, UNDEF_INTEGER, val, UNDEF_STRING, name, com)
    FitsCard(key::FitsKey, name::AbstractString, val::AbstractString, com::AbstractString) =
        new(key, FITS_STRING, UNDEF_INTEGER, UNDEF_COMPLEX, val, name, com)
    FitsCard(key::FitsKey, name::AbstractString, ::Undefined, com::AbstractString) =
        new(key, FITS_UNDEFINED, UNDEF_INTEGER, UNDEF_COMPLEX, UNDEF_STRING, name, com)
    FitsCard(key::FitsKey, name::AbstractString, ::Nothing, com::AbstractString) =
        new(key, key === Fits"END" ? FITS_END : FITS_COMMENT,
            UNDEF_INTEGER, UNDEF_COMPLEX, UNDEF_STRING, name, com)
end

# Constructor for imutable type does not need to return a new object.
FitsCard(A::FitsCard) = A
Base.convert(::Type{T}, A::FitsCard) where {T<:FitsCard} = A

"""
    FitsCard(buf; offset=0)

yields a `FitsCard` object built by parsing the FITS header card stored in the string or
vector of bytes `buf`. Keyword `offset` can be used to specify the number of bytes to skip
at the beginning of `buf`, so that it is possible to extract a specific FITS header card,
not just the first one. At most, the $FITS_CARD_SIZE first bytes after the offset are
scanned to build the `FitsCard` object. The next FITS card to parse is then at `offset +
$FITS_CARD_SIZE` and so on.

The considered card may be shorter than $FITS_CARD_SIZE bytes, the result being exactly
the same as if the missing bytes were spaces. If there are no bytes left, a `FitsCard`
object equivalent to the final `END` card of a FITS header is returned.

"""
function FitsCard(buf::ByteBuffer; offset::Int = 0)
    type, key, name_rng, val_rng, com_rng = scan_card(buf, offset)
    name = type == FITS_END ? END_STRING : make_string(buf, name_rng)
    com = make_string(buf, com_rng)
    if type == FITS_LOGICAL
        return FitsCard(key, name, parse_logical_value(buf, val_rng), com)
    elseif type == FITS_INTEGER
        return FitsCard(key, name, parse_integer_value(buf, val_rng), com)
    elseif type == FITS_FLOAT
        return FitsCard(key, name, parse_float_value(buf, val_rng), com)
    elseif type == FITS_STRING
        return FitsCard(key, name, parse_string_value(buf, val_rng), com)
    elseif type == FITS_COMPLEX
        return FitsCard(key, name, parse_complex_value(buf, val_rng), com)
    elseif type == FITS_UNDEFINED
        return FitsCard(key, name, undef, com)
    else # must be commentary or END card
        return FitsCard(key, name, nothing, com)
    end
end

is_structural(card::FitsCard) = is_structural(card.key)
is_comment(card::FitsCard) = is_comment(card.type)
is_naxis(card::FitsCard) = is_naxis(card.key)
is_end(card::FitsCard) = is_end(card.type)

# This version shall print something equivalent to Julia code to produce the same object.
# We try to use the most concise syntax.
function Base.show(io::IO, A::FitsCard)
    print(io, "FitsCard(\"")
    print(io, A.name, "\"")
    if A.type != FITS_END
        if A.type == FITS_COMMENT
            if A.key === Fits"COMMENT" || A.key === Fits"HISTORY"
                print(io, " => ")
                show(io, A.comment)
            else
                print(io, " => (nothing, ")
                show(io, A.comment)
                print(io, "=> (nothing, ")
            end
        else
            commented = !isempty(A.comment)
            if commented
                print(io, " => (")
            else
                print(io, " => ")
            end
            if A.type == FITS_LOGICAL
                print(io, A.logical ? "true" : "false")
            elseif A.type == FITS_INTEGER
                show(io, A.integer)
            elseif A.type == FITS_FLOAT
                show(io, A.float)
            elseif A.type == FITS_COMPLEX
                show(io, A.complex)
            elseif A.type == FITS_STRING
                show(io, A.string)
            elseif A.type == FITS_UNDEFINED
                print(io, "undef")
            end
            if commented
                print(io, ", ")
                show(io, A.comment)
                print(io, ")")
            end
        end
    end
    print(io, ")")
end

# This version is for the REPL. We try to approximate FITS syntax.
function Base.show(io::IO, mime::MIME"text/plain", A::FitsCard)
    print(io, "FitsCard: ")
    print(io, A.name)
    if A.type != FITS_END
        if A.key === Fits"HIERARCH"
            print(io, ' ')
        else
            n = ncodeunits(A.name)
            while n < FITS_SHORT_KEYWORD_SIZE
                print(io, ' ')
                n += 1
            end
        end
    end
    if A.type == FITS_COMMENT
        print(io, A.comment)
    elseif A.type != FITS_END
        print(io, "= ")
        if A.type == FITS_LOGICAL
            print(io, A.logical ? 'T' : 'F')
        elseif A.type == FITS_INTEGER
            show(io, A.integer)
        elseif A.type == FITS_FLOAT
            show(io, A.float)
        elseif A.type == FITS_COMPLEX
            print(io, "(")
            show(io, real(A.complex))
            print(io, ", ")
            show(io, imag(A.complex))
            print(io, ")")
        elseif A.type == FITS_STRING
            q = '\''
            print(io, q)
            for c in A.string
                if c == q
                    print(io, q, q)
                else
                    print(io, c)
                end
            end
            print(io, q)
        elseif A.type == FITS_UNDEFINED
            print(io, "<undefined>")
        end
        if !isempty(A.comment)
            print(io, " / ", A.comment)
        end
    end
end

# Callable object representing a FITS card value.
struct FitsCardValue
    parent::FitsCard
end
Base.parent(A::FitsCardValue) = getfield(A, :parent)
(A::FitsCardValue)() = get_value(parent(A))
(A::FitsCardValue)(::Type{T}) where {T} = get_value(T, parent(A))

Base.show(io::IO, A::FitsCardValue) = show(io, A())
Base.show(io::IO, mime::MIME"text/plain", A::FitsCardValue) = show(io, mime, A())

# General conversion rules.
Base.convert(::Type{T}, A::FitsCardValue) where {T<:FitsCardValue} = A
Base.convert(::Type{T}, A::FitsCardValue) where {T} = A(T)

# Explict conversion rules are to avoid ambiguities.
Base.convert(::Type{T}, A::FitsCardValue) where {T<:Number} = A(T)
for T in (Integer, Real, AbstractFloat, Complex,
          AbstractString, String, Nothing, Undef)
    @eval Base.convert(::Type{$T}, A::FitsCardValue) = A($T)
end

# `apply(f, A, B)` apply binary operator `f` to `A` and `B` at least one being a card
# value.
function apply(f, A::FitsCardValue, B::FitsCardValue)
    A = parent(A)
    type = get_type(A)
    type == FITS_LOGICAL   ? apply(f, get_value_logical(  A), B) :
    type == FITS_INTEGER   ? apply(f, get_value_integer(  A), B) :
    type == FITS_FLOAT     ? apply(f, get_value_float(    A), B) :
    type == FITS_STRING    ? apply(f, get_value_string(   A), B) :
    type == FITS_COMPLEX   ? apply(f, get_value_complex(  A), B) :
    type == FITS_UNDEFINED ? apply(f, undef, B) : apply(f, nothing, B)
end

function apply(f, A::FitsCardValue, B::Any)
    A = parent(A)
    type = get_type(A)
    type == FITS_LOGICAL   ? f(get_value_logical(  A), B) :
    type == FITS_INTEGER   ? f(get_value_integer(  A), B) :
    type == FITS_FLOAT     ? f(get_value_float(    A), B) :
    type == FITS_STRING    ? f(get_value_string(   A), B) :
    type == FITS_COMPLEX   ? f(get_value_complex(  A), B) :
    type == FITS_UNDEFINED ? f(undef, B) : f(nothing, B)
end

function apply(f, A::Any, B::FitsCardValue)
    B = parent(B)
    type = get_type(B)
    type == FITS_LOGICAL   ? f(A, get_value_logical(B)) :
    type == FITS_INTEGER   ? f(A, get_value_integer(B)) :
    type == FITS_FLOAT     ? f(A, get_value_float(  B)) :
    type == FITS_STRING    ? f(A, get_value_string( B)) :
    type == FITS_COMPLEX   ? f(A, get_value_complex(B)) :
    type == FITS_UNDEFINED ? f(A, undef) : f(A, nothing)
end

for op in (:(==), :(<))
    @eval begin
        Base.$op(A::FitsCardValue, B::FitsCardValue) = apply($op, A, B)
        Base.$op(A::FitsCardValue, B::Any) = apply($op, A, B)
        Base.$op(A::Any, B::FitsCardValue) = apply($op, A, B)
    end
end

# Conversion rules for a date. The FITS standard imposes ISO-8601 formatting for a date
# and time.
(A::FitsCardValue)(::Type{DateTime}) = parse(DateTime, A(String), ISODateTimeFormat)
Base.convert(::Type{DateTime}, A::FitsCardValue) = A(DateTime)
Dates.DateTime(A::FitsCardValue) = A(DateTime)

# If the FitsCard structure changes, it should be almost sufficient to change the
# following simple accessors.
get_type(         A::FitsCard) = getfield(A, :type)
get_key(          A::FitsCard) = getfield(A, :key)
get_name(         A::FitsCard) = getfield(A, :name)
get_comment(      A::FitsCard) = getfield(A, :comment)
get_value_logical(A::FitsCard) = !iszero(getfield(A, :value_integer))
get_value_integer(A::FitsCard) = getfield(A, :value_integer)
get_value_complex(A::FitsCard) = getfield(A, :value_complex)
get_value_float(  A::FitsCard) = real(get_value_complex(A))
get_value_string( A::FitsCard) = getfield(A, :value_string)
get_value(        A::FitsCard) = begin
    type = get_type(A)
    type == FITS_LOGICAL   ? get_value_logical(A) :
    type == FITS_INTEGER   ? get_value_integer(A) :
    type == FITS_FLOAT     ? get_value_float(  A) :
    type == FITS_STRING    ? get_value_string( A) :
    type == FITS_COMPLEX   ? get_value_complex(A) :
    type == FITS_UNDEFINED ? undef :
    nothing # FITS_COMMENT or FITS_END
end
get_value(::Type{Undef}, A::FitsCard) =
    get_type(A) == FITS_UNDEFINED ? undef : conversion_error(Undef, A)
get_value(::Type{Nothing}, A::FitsCard) =
    ((get_type(A) == FITS_COMMENT)|(get_type(A) == FITS_END)) ? nothing : conversion_error(Nothing, A)
get_value(::Type{String}, A::FitsCard) =
    get_type(A) == FITS_STRING ? get_value_string(A) : conversion_error(String, A)
get_value(::Type{Bool}, A::FitsCard) = begin
    type = get_type(A)
    type == FITS_LOGICAL  ?               get_value_logical(A)  :
    type == FITS_INTEGER  ? convert(Bool, get_value_integer(A)) :
    type == FITS_FLOAT    ? convert(Bool, get_value_float(  A)) :
    type == FITS_COMPLEX  ? convert(Bool, get_value_complex(A)) :
    conversion_error(Bool, A)
end
get_value(::Type{FitsInteger}, A::FitsCard) = begin
    type = get_type(A)
    type == FITS_INTEGER  ?                      get_value_integer(A)  :
    type == FITS_LOGICAL  ? convert(FitsInteger, get_value_logical(A)) :
    type == FITS_FLOAT    ? convert(FitsInteger, get_value_float(  A)) :
    type == FITS_COMPLEX  ? convert(FitsInteger, get_value_complex(A)) :
    conversion_error(FitsInteger, A)
end
get_value(::Type{FitsFloat}, A::FitsCard) = begin
    type = get_type(A)
    type == FITS_FLOAT    ?                    get_value_float(  A)  :
    type == FITS_LOGICAL  ? convert(FitsFloat, get_value_logical(A)) :
    type == FITS_INTEGER  ? convert(FitsFloat, get_value_integer(A)) :
    type == FITS_COMPLEX  ? convert(FitsFloat, get_value_complex(A)) :
    conversion_error(FitsFloat, A)
end
get_value(::Type{FitsComplex}, A::FitsCard) = begin
    type = get_type(A)
    type == FITS_COMPLEX  ?                      get_value_complex(A)  :
    type == FITS_FLOAT    ? convert(FitsComplex, get_value_float(  A)) :
    type == FITS_LOGICAL  ? convert(FitsComplex, get_value_logical(A)) :
    type == FITS_INTEGER  ? convert(FitsComplex, get_value_integer(A)) :
    conversion_error(FitsComplex, A)
end
get_value(::Type{Integer},        A::FitsCard) = get_value(FitsInteger, A)
get_value(::Type{Real},           A::FitsCard) = get_value(FitsFloat,   A)
get_value(::Type{AbstractFloat},  A::FitsCard) = get_value(FitsFloat,   A)
get_value(::Type{Complex},        A::FitsCard) = get_value(FitsComplex, A)
get_value(::Type{AbstractString}, A::FitsCard) = get_value(String,      A)
get_value(::Type{T}, A::FitsCard) where {T<:Number} = begin
    type = get_type(A)
    type == FITS_LOGICAL  ? convert(T, get_value_logical(A)) :
    type == FITS_INTEGER  ? convert(T, get_value_integer(A)) :
    type == FITS_FLOAT    ? convert(T, get_value_float(  A)) :
    type == FITS_COMPLEX  ? convert(T, get_value_complex(A)) :
    conversion_error(T, A)
end
get_value(::Type{T}, A::FitsCard) where {T} = conversion_error(T, A) # catch errors
@noinline conversion_error(::Type{T}, A::FitsCard) where {T} =
    error("value of FITS keyword \"$(get_name(A))\" cannot be converted to `$T`")

# Properties.
Base.propertynames(A::FitsCard) =
    (:type, :key, :name, :value, :comment, :logical, :integer, :float, :complex,
     :string, :units, :unitless)
Base.getproperty(A::FitsCard, sym::Symbol) = getproperty(A, Val(sym))
Base.getproperty(A::FitsCard, ::Val{:type    }) = get_type(A)
Base.getproperty(A::FitsCard, ::Val{:key     }) = get_key(A)
Base.getproperty(A::FitsCard, ::Val{:name    }) = get_name(A)
Base.getproperty(A::FitsCard, ::Val{:value   }) = FitsCardValue(A)
Base.getproperty(A::FitsCard, ::Val{:comment }) = get_comment(A)
Base.getproperty(A::FitsCard, ::Val{:logical }) = get_value(Bool, A)
Base.getproperty(A::FitsCard, ::Val{:integer }) = get_value(FitsInteger, A)
Base.getproperty(A::FitsCard, ::Val{:float   }) = get_value(FitsFloat, A)
Base.getproperty(A::FitsCard, ::Val{:string  }) = get_value(String, A)
Base.getproperty(A::FitsCard, ::Val{:complex }) = get_value(FitsComplex, A)
Base.getproperty(A::FitsCard, ::Val{:units   }) = get_units_part(get_comment(A))
Base.getproperty(A::FitsCard, ::Val{:unitless}) = get_unitless_part(get_comment(A))
@noinline Base.setproperty!(A::FitsCard, sym::Symbol, x) =
    error("attempt to set read-only property of FITS card")

"""
    FitsCardType(T)

yields the FITS header card type code corresponding to Julia type `T`, one of:
`FITS_LOGICAL`, `FITS_INTEGER`, `FITS_FLOAT`, `FITS_COMPLEX`, `FITS_STRING`,
`FITS_COMMENT`, or `FITS_UNDEFINED`.

"""
FitsCardType(::Type{<:Bool})           = FITS_LOGICAL
FitsCardType(::Type{<:Integer})        = FITS_INTEGER
FitsCardType(::Type{<:AbstractFloat})  = FITS_FLOAT
FitsCardType(::Type{<:Complex})        = FITS_COMPLEX
FitsCardType(::Type{<:AbstractString}) = FITS_STRING
FitsCardType(::Type{<:Nothing})        = FITS_COMMENT
FitsCardType(::Type{<:Undefined})      = FITS_UNDEFINED

"""
    FitsCardType(card::FitsCard)
    card.type

yield the type code of the FITS header card `card`, one of: `FITS_LOGICAL`,
`FITS_INTEGER`, `FITS_FLOAT`, `FITS_COMPLEX`, `FITS_STRING`, `FITS_COMMENT`, or
`FITS_UNDEFINED`.

"""
FitsCardType(A::FitsCard) = get_type(A)

Base.isassigned(A::FitsCard) =
    (A.type != FITS_COMMENT) & (A.type != FITS_UNDEFINED) & (A.type != FITS_END)

Base.isinteger(A::FitsCard) =
    (A.type == FITS_INTEGER) | (A.type == FITS_LOGICAL)

Base.isreal(A::FitsCard) =
    (A.type == FITS_FLOAT) |
    (A.type == FITS_INTEGER) |
    (A.type == FITS_LOGICAL) |
    (A.type == FITS_COMPLEX && iszero(imag(get_value_complex(A))))

"""
    valtype(x::Union{FitsCard,FitsCardType}) -> T

yields the Julia type `T` corresponding to a given FITS card or card type.

"""
@inline Base.valtype(A::FitsCard) = valtype(A.type)
Base.valtype(t::FitsCardType) =
    t === FITS_LOGICAL   ? Bool        :
    t === FITS_INTEGER   ? FitsInteger :
    t === FITS_FLOAT     ? FitsFloat   :
    t === FITS_STRING    ? String      :
    t === FITS_COMPLEX   ? FitsComplex :
    t === FITS_COMMENT   ? Nothing     :
    t === FITS_UNDEFINED ? Undef       :
    t === FITS_END       ? Nothing     :
    throw(ArgumentError("unexpected FITS card type"))

# FITS cards can be specified as pairs and conversely.
Base.convert(::Type{T}, A::FitsCard) where {T<:Pair} = T(A)
Base.convert(::Type{T}, pair::Pair) where {T<:FitsCard} = T(pair)
Base.Pair(A::FitsCard) = Pair(A.name, (A.value(), A.comment))
Base.Pair{K}(A::FitsCard) where {K} = Pair(as(K, A.name), (A.value(), A.comment))
Base.Pair{K,V}(A::FitsCard) where {K,V} = Pair(as(K, A.name), as(V, (A.value(), A.comment)))
FitsCard(pair::Pair{<:CardName, <:Any}) = build_card(pair...)

# Private helper function to build a FitsCard instance.
build_card(name::CardName, x) = build_card(check_keyword(name)..., x)
build_card(key::FitsKey, name::AbstractString, x::Tuple{CardValueExt,CardComment}) =
    FitsCard(key, name, to_value(x[1]), to_comment(x[2]))
build_card(key::FitsKey, name::AbstractString, x::Tuple{CardValueExt}) =
    FitsCard(key, name, to_value(x[1]), to_comment())
build_card(key::FitsKey, name::AbstractString, x::CardValueExt) =
    FitsCard(key, name, to_value(x), to_comment())
build_card(key::FitsKey, name::AbstractString, x::AbstractString) =
    is_comment(key) ? FitsCard(key, name, nothing, x) : FitsCard(key, name, x, to_comment())
@noinline build_card(key::FitsKey, name::AbstractString, x::X) where {X} =
    throw(ArgumentError("invalid value and/or comment of type `$X` for FITS keyword `$name`"))

# Yield a bare card value.  See alias `CardValueExt`.
to_value(val::CardValue) = val
to_value(val::DateTime) = Dates.format(val, ISODateTimeFormat)

# Yield a string from any instance of CardComment.
to_comment() = to_comment(nothing)
to_comment(com::AbstractString) = com
to_comment(com::Nothing) = EMPTY_STRING

end # module
