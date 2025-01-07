module TestingFITSHeaders

using TypeUtils
using Dates
using Test
using FITSHeaders
using FITSHeaders:
    FitsInteger, FitsFloat, FitsComplex,
    is_structural, is_comment, is_naxis, is_end

@static if ENDIAN_BOM == 0x04030201
    const BYTE_ORDER = :little_endian
    order_bytes(x) = bswap(x)
elseif ENDIAN_BOM == 0x01020304
    const BYTE_ORDER = :big_endian
    order_bytes(x) = x
else
    error("unsupported byte order")
end

# Returns is only defined for Julia ≥ 1.7
struct Returns{V} <: Function; val::V; end
(obj::Returns)(args...; kwds...) = obj.val

make_FitsKey(str::AbstractString) =
    FitsKey(reinterpret(UInt64,UInt8[c for c in str])[1])

function make_byte_vector(str::AbstractString)
    @assert codeunit(str) === UInt8
    vec = Array{UInt8}(undef, ncodeunits(str))
    I, = axes(vec)
    k = firstindex(str) - first(I)
    for i in I
        vec[i] = codeunit(str, i + k)
    end
    return vec
end

function make_discontinuous_byte_vector(str::AbstractString)
    @assert codeunit(str) === UInt8
    arr = Array{UInt8}(undef, 2, ncodeunits(str))
    I, J = axes(arr)
    i = last(I)
    k = firstindex(str) - first(J)
    for j in J
        arr[i,j] = codeunit(str, j + k)
    end
    return view(arr, i, :)
end

_load(::Type{T}, buf::Vector{UInt8}, off::Integer = 0) where {T} =
    GC.@preserve buf unsafe_load(Base.unsafe_convert(Ptr{T}, buf) + off)
_store!(::Type{T}, buf::Vector{UInt8}, x, off::Integer = 0) where {T} =
    GC.@preserve buf unsafe_store!(Base.unsafe_convert(Ptr{T}, buf) + off, as(T, x))

@testset "FITSHeaders.jl" begin
    @testset "Assertions" begin
        # Check that `unsafe_load` and `unsafe_store!` are unaligned operations
        # and that in `pointer + offset` expression the offset is in bytes (not
        # in number of elements).
        let buf = UInt8[b for b in 0x00:0xFF],
            ptr = Base.unsafe_convert(Ptr{UInt64}, buf)
            @test _load(UInt64, buf, 0) === order_bytes(0x0001020304050607)
            @test _load(UInt64, buf, 1) === order_bytes(0x0102030405060708)
            @test _load(UInt64, buf, 2) === order_bytes(0x0203040506070809)
            @test _load(UInt64, buf, 3) === order_bytes(0x030405060708090A)
            @test _load(UInt64, buf, 4) === order_bytes(0x0405060708090A0B)
            @test _load(UInt64, buf, 5) === order_bytes(0x05060708090A0B0C)
            @test _load(UInt64, buf, 6) === order_bytes(0x060708090A0B0C0D)
            @test _load(UInt64, buf, 7) === order_bytes(0x0708090A0B0C0D0E)
            val = order_bytes(0x0102030405060708)
            for i in 0:7
                _store!(UInt64, fill!(buf, 0x00), val, i)
                for j in 0:7
                    @test _load(UInt64, buf, j) === (val >> (8*(j - i)))
                end
            end
        end
        @test sizeof(FitsKey) == 8
        @test FITS_SHORT_KEYWORD_SIZE == 8
        @test FITS_CARD_SIZE == 80
        @test FITS_BLOCK_SIZE == 2880
    end
    @testset "FitsCardType" begin
        @test FitsCardType(Bool) === FITS_LOGICAL
        @test FitsCardType(Int16) === FITS_INTEGER
        @test FitsCardType(Float32) === FITS_FLOAT
        @test FitsCardType(ComplexF64) === FITS_COMPLEX
        @test FitsCardType(String) === FITS_STRING
        @test FitsCardType(Nothing) === FITS_COMMENT
        @test FitsCardType(UndefInitializer) === FITS_UNDEFINED
        @test FitsCardType(Missing) === FITS_UNDEFINED
    end
    @testset "Keywords" begin
        @test iszero(FitsKey())
        @test zero(FitsKey()) === FitsKey()
        @test zero(FitsKey) === FitsKey()
        @test convert(Integer, FitsKey()) === zero(UInt64)
        @test convert(FitsKey, 1234) === FitsKey(1234)
        @test convert(FitsKey, FitsKey(1234)) === FitsKey(1234)
        @test UInt64(FitsKey()) === zero(UInt64)
        @test Fits"SIMPLE"   ==  make_FitsKey("SIMPLE  ")
        @test Fits"SIMPLE"   === make_FitsKey("SIMPLE  ")
        @test Fits"BITPIX"   === make_FitsKey("BITPIX  ")
        @test Fits"NAXIS"    === make_FitsKey("NAXIS   ")
        @test Fits"COMMENT"  === make_FitsKey("COMMENT ")
        @test Fits"HISTORY"  === make_FitsKey("HISTORY ")
        @test Fits"HIERARCH" === make_FitsKey("HIERARCH")
        @test Fits""         === make_FitsKey("        ")
        @test Fits"END"      === make_FitsKey("END     ")
        @test String(Fits"") == ""
        @test String(Fits"SIMPLE") == "SIMPLE"
        @test String(Fits"HIERARCH") == "HIERARCH"
        @test repr(Fits"") == "Fits\"\""
        @test repr(Fits"SIMPLE") == "Fits\"SIMPLE\""
        @test repr(Fits"HIERARCH") == "Fits\"HIERARCH\""
        @test repr("text/plain", Fits"") == "Fits\"\""
        @test repr("text/plain", Fits"SIMPLE") == "Fits\"SIMPLE\""
        @test repr("text/plain", Fits"HIERARCH") == "Fits\"HIERARCH\""
        @test string(FitsKey()) == "FitsKey(0x0000000000000000)"
        @test string(Fits"SIMPLE") == "Fits\"SIMPLE\""
        @test string(Fits"HISTORY") == "Fits\"HISTORY\""
        @test_throws Exception FITSHeaders.keyword("SIMPLE#")
        @test_throws Exception FITSHeaders.keyword(" SIMPLE")
        @test_throws Exception FITSHeaders.keyword("SIMPLE ")
        @test_throws Exception FITSHeaders.keyword("TOO  MANY SPACES")
        @test_throws Exception FITSHeaders.keyword("HIERARCH  A") # more than one space
        @test_throws Exception FITSHeaders.keyword("HIERARCH+ A") # invalid character
        # Short FITS keywords.
        @test FITSHeaders.try_parse_keyword("SIMPLE") == (Fits"SIMPLE", false)
        @test FITSHeaders.keyword("SIMPLE") == "SIMPLE"
        @test FITSHeaders.keyword(:SIMPLE) == "SIMPLE"
        @test FITSHeaders.try_parse_keyword("HISTORY") == (Fits"HISTORY", false)
        @test FITSHeaders.keyword("HISTORY") == "HISTORY"
        # Keywords longer than 8-characters are HIERARCH ones.
        @test FITSHeaders.try_parse_keyword("LONG-NAME") == (Fits"HIERARCH", true)
        @test FITSHeaders.keyword("LONG-NAME") == "HIERARCH LONG-NAME"
        @test FITSHeaders.try_parse_keyword("Mixed") == (Fits"HIERARCH", true)
        @test FITSHeaders.keyword("Mixed") == "HIERARCH Mixed"
        @test FITSHeaders.try_parse_keyword("HIERARCHY") == (Fits"HIERARCH", true)
        @test FITSHeaders.keyword("HIERARCHY") == "HIERARCH HIERARCHY"
        # Keywords starting by "HIERARCH " are HIERARCH ones.
        for key in ("HIERARCH GIZMO", "HIERARCH MY GIZMO", "HIERARCH MY BIG GIZMO")
            @test FITSHeaders.try_parse_keyword(key) == (Fits"HIERARCH", false)
            @test FITSHeaders.keyword(key) === key # should return the same object
        end
        # Keywords with multiple words are HIERARCH ones whatever their lengths.
        for key in ("A B", "A B C", "SOME KEY", "TEST CASE")
            @test FITSHeaders.try_parse_keyword(key) == (Fits"HIERARCH", true)
            @test FITSHeaders.keyword(key) == "HIERARCH "*key
        end
        # The following cases are consequences of the implemented scanner.
        @test FITSHeaders.try_parse_keyword("HIERARCH") == (Fits"HIERARCH", false)
        @test FITSHeaders.keyword("HIERARCH") == "HIERARCH"
        @test FITSHeaders.try_parse_keyword("HIERARCH SIMPLE") == (Fits"HIERARCH", false)
        @test FITSHeaders.keyword("HIERARCH SIMPLE") == "HIERARCH SIMPLE"

        @test  is_structural(Fits"SIMPLE")
        @test  is_structural(Fits"BITPIX")
        @test  is_structural(Fits"NAXIS")
        @test  is_structural(Fits"NAXIS1")
        @test  is_structural(Fits"NAXIS999")
        @test  is_structural(Fits"XTENSION")
        @test  is_structural(Fits"TFIELDS")
        @test !is_structural(Fits"TTYPE")
        @test  is_structural(Fits"TTYPE1")
        @test  is_structural(Fits"TTYPE999")
        @test !is_structural(Fits"TFORM")
        @test  is_structural(Fits"TFORM1")
        @test  is_structural(Fits"TFORM999")
        @test !is_structural(Fits"TDIM")
        @test  is_structural(Fits"TDIM1")
        @test  is_structural(Fits"TDIM999")
        @test  is_structural(Fits"PCOUNT")
        @test  is_structural(Fits"GCOUNT")
        @test  is_structural(Fits"END")
        @test !is_structural(Fits"COMMENT")
        @test !is_structural(Fits"HISTORY")
        @test !is_structural(Fits"HIERARCH")

        @test !is_comment(Fits"SIMPLE")
        @test !is_comment(Fits"BITPIX")
        @test !is_comment(Fits"NAXIS")
        @test !is_comment(Fits"NAXIS1")
        @test !is_comment(Fits"NAXIS999")
        @test !is_comment(Fits"XTENSION")
        @test !is_comment(Fits"TFIELDS")
        @test !is_comment(Fits"TTYPE")
        @test !is_comment(Fits"TTYPE1")
        @test !is_comment(Fits"TTYPE999")
        @test !is_comment(Fits"TFORM")
        @test !is_comment(Fits"TFORM1")
        @test !is_comment(Fits"TFORM999")
        @test !is_comment(Fits"TDIM")
        @test !is_comment(Fits"TDIM1")
        @test !is_comment(Fits"TDIM999")
        @test !is_comment(Fits"PCOUNT")
        @test !is_comment(Fits"GCOUNT")
        @test !is_comment(Fits"END")
        @test  is_comment(Fits"COMMENT")
        @test  is_comment(Fits"HISTORY")
        @test !is_comment(Fits"HIERARCH")

        @test !is_naxis(Fits"SIMPLE")
        @test !is_naxis(Fits"BITPIX")
        @test  is_naxis(Fits"NAXIS")
        @test  is_naxis(Fits"NAXIS1")
        @test  is_naxis(Fits"NAXIS999")
        @test !is_naxis(Fits"XTENSION")
        @test !is_naxis(Fits"TFIELDS")
        @test !is_naxis(Fits"TTYPE")
        @test !is_naxis(Fits"TTYPE1")
        @test !is_naxis(Fits"TTYPE999")
        @test !is_naxis(Fits"TFORM")
        @test !is_naxis(Fits"TFORM1")
        @test !is_naxis(Fits"TFORM999")
        @test !is_naxis(Fits"TDIM")
        @test !is_naxis(Fits"TDIM1")
        @test !is_naxis(Fits"TDIM999")
        @test !is_naxis(Fits"PCOUNT")
        @test !is_naxis(Fits"GCOUNT")
        @test !is_naxis(Fits"END")
        @test !is_naxis(Fits"COMMENT")
        @test !is_naxis(Fits"HISTORY")
        @test !is_naxis(Fits"HIERARCH")

        @test !is_end(Fits"SIMPLE")
        @test !is_end(Fits"BITPIX")
        @test !is_end(Fits"NAXIS")
        @test !is_end(Fits"NAXIS1")
        @test !is_end(Fits"NAXIS999")
        @test !is_end(Fits"XTENSION")
        @test !is_end(Fits"TFIELDS")
        @test !is_end(Fits"TTYPE")
        @test !is_end(Fits"TTYPE1")
        @test !is_end(Fits"TTYPE999")
        @test !is_end(Fits"TFORM")
        @test !is_end(Fits"TFORM1")
        @test !is_end(Fits"TFORM999")
        @test !is_end(Fits"TDIM")
        @test !is_end(Fits"TDIM1")
        @test !is_end(Fits"TDIM999")
        @test !is_end(Fits"PCOUNT")
        @test !is_end(Fits"GCOUNT")
        @test  is_end(Fits"END")
        @test !is_end(Fits"COMMENT")
        @test !is_end(Fits"HISTORY")
        @test !is_end(Fits"HIERARCH")
    end
    @testset "Parser" begin
        # Byte order.
        @test FITSHeaders.Parser.BIG_ENDIAN === (BYTE_ORDER === :big_endian)
        @test FITSHeaders.Parser.LITTLE_ENDIAN === (BYTE_ORDER === :little_endian)
        # Character classes according to FITS standard.
        for b in 0x00:0xFF
            c = Char(b)
            @test FITSHeaders.Parser.is_digit(c) === ('0' ≤ c ≤ '9')
            @test FITSHeaders.Parser.is_uppercase(c) === ('A' ≤ c ≤ 'Z')
            @test FITSHeaders.Parser.is_lowercase(c) === ('a' ≤ c ≤ 'z')
            @test FITSHeaders.Parser.is_space(c) === (c == ' ')
            @test FITSHeaders.Parser.is_quote(c) === (c == '\'')
            @test FITSHeaders.Parser.is_equals_sign(c) === (c == '=')
            @test FITSHeaders.Parser.is_hyphen(c) === (c == '-')
            @test FITSHeaders.Parser.is_underscore(c) === (c == '_')
            @test FITSHeaders.Parser.is_comment_separator(c) === (c == '/')
            @test FITSHeaders.Parser.is_opening_parenthesis(c) === (c == '(')
            @test FITSHeaders.Parser.is_closing_parenthesis(c) === (c == ')')
            @test FITSHeaders.Parser.is_restricted_ascii(c) === (' ' ≤ c ≤ '~')
            @test FITSHeaders.Parser.is_keyword(c) ===
                (('0' ≤ c ≤ '9') | ('A' ≤ c ≤ 'Z') | (c == '-') | (c == '_'))
        end
        # Trimming of spaces.
        for str in ("", "  a string ", "another string", "  yet  another  string    ")
            @test SubString(str, FITSHeaders.Parser.trim_leading_spaces(str)) == lstrip(str)
            @test SubString(str, FITSHeaders.Parser.trim_trailing_spaces(str)) == rstrip(str)
            rng = firstindex(str):ncodeunits(str)
            @test SubString(str, FITSHeaders.Parser.trim_leading_spaces(str, rng)) == lstrip(str)
            @test SubString(str, FITSHeaders.Parser.trim_trailing_spaces(str, rng)) == rstrip(str)
        end
        # Representation of a character.
        @test FITSHeaders.Parser.repr_char(' ') == repr(' ')
        @test FITSHeaders.Parser.repr_char(0x20) == repr(' ')
        @test FITSHeaders.Parser.repr_char('\0') == repr(0x00)
        @test FITSHeaders.Parser.repr_char(0x00) == repr(0x00)
        @test FITSHeaders.Parser.repr_char('i') == repr('i')
        @test FITSHeaders.Parser.repr_char(0x69) == repr('i')
        # FITS logical value.
        @test FITSHeaders.Parser.try_parse_logical_value("T") === true
        @test FITSHeaders.Parser.try_parse_logical_value("F") === false
        @test FITSHeaders.Parser.try_parse_logical_value("t") === nothing
        @test FITSHeaders.Parser.try_parse_logical_value("f") === nothing
        @test FITSHeaders.Parser.try_parse_logical_value("true") === nothing
        @test FITSHeaders.Parser.try_parse_logical_value("false") === nothing
        # FITS integer value.
        for val in (zero(Int64), typemin(Int64), typemax(Int64))
            str = "$val"
            @test FITSHeaders.Parser.try_parse_integer_value(str) == val
            if val > 0
                # Add a few leading zeros.
                str = "000$val"
                @test FITSHeaders.Parser.try_parse_integer_value(str) == val
            end
            @test FITSHeaders.Parser.try_parse_integer_value(" "*str) === nothing
            @test FITSHeaders.Parser.try_parse_integer_value(str*" ") === nothing
        end
        # FITS float value;
        for val in (0.0, 1.0, -1.0, float(π))
            str = "$val"
            @test FITSHeaders.Parser.try_parse_float_value(str) ≈ val
            @test FITSHeaders.Parser.try_parse_integer_value(" "*str) === nothing
            @test FITSHeaders.Parser.try_parse_integer_value(str*" ") === nothing
        end
        # FITS complex value;
        @test FITSHeaders.Parser.try_parse_float_value("2.3d4") ≈ 2.3e4
        @test FITSHeaders.Parser.try_parse_float_value("-1.09D3") ≈ -1.09e3
        @test FITSHeaders.Parser.try_parse_complex_value("(2.3d4,-1.8)") ≈ complex(2.3e4,-1.8)
        @test FITSHeaders.Parser.try_parse_complex_value("(-1.09e5,7.6D2)") ≈ complex(-1.09e5,7.6e2)
        # FITS string value;
        @test FITSHeaders.Parser.try_parse_string_value("''") == ""
        @test FITSHeaders.Parser.try_parse_string_value("'''") === nothing
        @test FITSHeaders.Parser.try_parse_string_value("''''") == "'"
        @test FITSHeaders.Parser.try_parse_string_value("'Hello!'") == "Hello!"
        @test FITSHeaders.Parser.try_parse_string_value("'Hello! '") == "Hello!"
        @test FITSHeaders.Parser.try_parse_string_value("' Hello!'") == " Hello!"
        @test FITSHeaders.Parser.try_parse_string_value("' Hello! '") == " Hello!"
        @test FITSHeaders.Parser.try_parse_string_value("' Hello! '") == " Hello!"
        @test FITSHeaders.Parser.try_parse_string_value("'Joe''s taxi'") == "Joe's taxi"
        @test FITSHeaders.Parser.try_parse_string_value("'Joe's taxi'") === nothing
        @test FITSHeaders.Parser.try_parse_string_value("'Joe'''s taxi'") === nothing
        # Units.
        let com = ""
            @test FITSHeaders.Parser.get_units_part(com) == ""
            @test FITSHeaders.Parser.get_unitless_part(com) == ""
        end
        let com = "some comment"
            @test FITSHeaders.Parser.get_units_part(com) == ""
            @test FITSHeaders.Parser.get_unitless_part(com) == "some comment"
        end
        let com = "[]some comment"
            @test FITSHeaders.Parser.get_units_part(com) == ""
            @test FITSHeaders.Parser.get_unitless_part(com) == "some comment"
        end
        let com = "[] some comment"
            @test FITSHeaders.Parser.get_units_part(com) == ""
            @test FITSHeaders.Parser.get_unitless_part(com) == "some comment"
        end
        let com = "[some units]some comment"
            @test FITSHeaders.Parser.get_units_part(com) == "some units"
            @test FITSHeaders.Parser.get_unitless_part(com) == "some comment"
        end
        let com = "[  some units   ]  some comment"
            @test FITSHeaders.Parser.get_units_part(com) == "some units"
            @test FITSHeaders.Parser.get_unitless_part(com) == "some comment"
        end
        let com = "[some comment"
            @test FITSHeaders.Parser.get_units_part(com) == ""
            @test FITSHeaders.Parser.get_unitless_part(com) == "[some comment"
        end
    end
    @testset "Cards from strings" begin
        # Errors...
        @test_throws Exception FitsCard("END     nothing allowed here")
        @test_throws Exception FitsCard("VALUE   =     # / invalid character")
        @test_throws Exception FitsCard("VALUE   =  .-123 / invalid number")
        @test_throws Exception FitsCard("VALUE   =  -12x3 / invalid number")
        @test_throws Exception FitsCard("VALUE   = (1,3.0 / unclosed complex")
        @test_throws Exception FitsCard("VALUE   =   (1,) / bad complex")
        @test_throws Exception FitsCard("VALUE   =   (,1) / bad complex")
        @test_throws Exception FitsCard("VALUE   = 'hello / unclosed string")
        @test_throws Exception FitsCard("VALUE   = 'Joe's taxi' / unescaped quote")
        # Logical FITS cards.
        let card = FitsCard("SIMPLE  =                    T / this is a FITS file                     ")
            @test :type ∈ propertynames(card)
            @test :name ∈ propertynames(card)
            @test :key ∈ propertynames(card)
            @test :value ∈ propertynames(card)
            @test :comment ∈ propertynames(card)
            @test :units ∈ propertynames(card)
            @test :unitless ∈ propertynames(card)
            @test :logical ∈ propertynames(card)
            @test :integer ∈ propertynames(card)
            @test :float ∈ propertynames(card)
            @test :complex ∈ propertynames(card)
            @test :string ∈ propertynames(card)
            @test card.type === FITS_LOGICAL
            @test FitsCardType(card) === FITS_LOGICAL
            @test card.key == Fits"SIMPLE"
            @test card.name == "SIMPLE"
            @test card.comment == "this is a FITS file"
            @test card.value() isa Bool
            @test card.value() == true
            @test card.value() === card.logical
            @test valtype(card) === typeof(card.value())
            @test card.value(valtype(card)) === card.value()
            @test isassigned(card) === true
            @test isinteger(card) === true
            @test isreal(card) === true
            @test_throws Exception card.key = Fits"HISTORY"
            # Convert callable value object by calling the object itself.
            @test card.value(valtype(card)) === card.value()
            @test card.value(Bool)          === convert(Bool,        card.value())
            @test card.value(Int16)         === convert(Int16,       card.value())
            @test card.value(Integer)       === convert(FitsInteger, card.value())
            @test card.value(Real)          === convert(FitsFloat,   card.value())
            @test card.value(AbstractFloat) === convert(FitsFloat,   card.value())
            @test card.value(Complex)       === convert(FitsComplex, card.value())
            @test_throws Exception card.value(String)
            @test_throws Exception card.value(AbstractString)
            # Convert callable value object by calling `convert`.
            @test convert(typeof(card.value), card.value) === card.value
            @test convert(valtype(card), card.value) === card.value()
            @test convert(Bool,          card.value) === card.value(Bool)
            @test convert(Int16,         card.value) === card.value(Int16)
            @test convert(Integer,       card.value) === card.value(Integer)
            @test convert(Real,          card.value) === card.value(Real)
            @test convert(AbstractFloat, card.value) === card.value(AbstractFloat)
            @test convert(Complex,       card.value) === card.value(Complex)
            @test_throws Exception convert(String,         card.value)
            @test_throws Exception convert(AbstractString, card.value)
            # Various string representations.
            @test repr(card) isa String
            @test repr("text/plain", card) isa String
            @test repr(card.value) isa String
            @test repr("text/plain", card.value) isa String
        end
        # Integer valued cards.
        let card = FitsCard("BITPIX  =                  -32 / number of bits per data pixel           ")
            @test card.type == FITS_INTEGER
            @test card.key == Fits"BITPIX"
            @test card.name == "BITPIX"
            @test card.comment == "number of bits per data pixel"
            @test card.value() isa FitsInteger
            @test card.value() == -32
            @test card.value() === card.integer
            @test valtype(card) === typeof(card.value())
            @test card.value(valtype(card)) === card.value()
            @test isassigned(card) === true
            @test isinteger(card) === true
            @test isreal(card) === true
            # Convert callable value object by calling the object itself.
            @test card.value(valtype(card)) === card.value()
            @test card.value(Int16)         === convert(Int16,       card.value())
            @test card.value(Integer)       === convert(FitsInteger, card.value())
            @test card.value(Real)          === convert(FitsFloat,   card.value())
            @test card.value(AbstractFloat) === convert(FitsFloat,   card.value())
            @test card.value(Complex)       === convert(FitsComplex, card.value())
            @test_throws InexactError card.value(Bool)
            @test_throws Exception    card.value(String)
            @test_throws Exception    card.value(AbstractString)
            # Convert callable value object by calling `convert`.
            @test convert(valtype(card), card.value) === card.value()
            @test convert(Int16,         card.value) === card.value(Int16)
            @test convert(Integer,       card.value) === card.value(Integer)
            @test convert(Real,          card.value) === card.value(Real)
            @test convert(AbstractFloat, card.value) === card.value(AbstractFloat)
            @test convert(Complex,       card.value) === card.value(Complex)
            @test_throws InexactError convert(Bool,           card.value)
            @test_throws Exception    convert(String,         card.value)
            @test_throws Exception    convert(AbstractString, card.value)
             # Various string representations.
            @test repr(card) isa String
            @test repr("text/plain", card) isa String
            @test repr(card.value) isa String
            @test repr("text/plain", card.value) isa String
        end
        let card = FitsCard("NAXIS   =                    3 /      number of axes                      ")
            @test card.type == FITS_INTEGER
            @test card.key == Fits"NAXIS"
            @test card.name == "NAXIS"
            @test card.comment == "number of axes"
            @test card.units == ""
            @test card.unitless == "number of axes"
            @test card.value() isa FitsInteger
            @test card.value() == 3
            @test card.value() === card.integer
            @test valtype(card) === typeof(card.value())
            @test card.value(valtype(card)) === card.value()
            @test isassigned(card) === true
            @test isinteger(card) === true
            @test isreal(card) === true
            # Convert callable value object by calling the object itself.
            @test card.value(valtype(card)) === card.value()
            @test card.value(Int16)         === convert(Int16,       card.value())
            @test card.value(Integer)       === convert(FitsInteger, card.value())
            @test card.value(Real)          === convert(FitsFloat,   card.value())
            @test card.value(AbstractFloat) === convert(FitsFloat,   card.value())
            @test card.value(Complex)       === convert(FitsComplex, card.value())
            @test_throws InexactError card.value(Bool)
            @test_throws Exception    card.value(String)
            @test_throws Exception    card.value(AbstractString)
            # Convert callable value object by calling `convert`.
            @test convert(valtype(card), card.value) === card.value()
            @test convert(Int16,         card.value) === card.value(Int16)
            @test convert(Integer,       card.value) === card.value(Integer)
            @test convert(Real,          card.value) === card.value(Real)
            @test convert(AbstractFloat, card.value) === card.value(AbstractFloat)
            @test convert(Complex,       card.value) === card.value(Complex)
            @test_throws InexactError convert(Bool,           card.value)
            @test_throws Exception    convert(String,         card.value)
            @test_throws Exception    convert(AbstractString, card.value)
            # Various string representations.
            @test repr(card) isa String
            @test repr("text/plain", card) isa String
            @test repr(card.value) isa String
            @test repr("text/plain", card.value) isa String
        end
        # COMMENT and HISTORY.
        let card = FitsCard("COMMENT   Some comments (with leading spaces that should not be removed) ")
            @test card.type == FITS_COMMENT
            @test card.key == Fits"COMMENT"
            @test card.name == "COMMENT"
            @test card.comment == "  Some comments (with leading spaces that should not be removed)"
            @test card.value() isa Nothing
            @test card.value() === nothing
            @test valtype(card) === typeof(card.value())
            @test card.value(valtype(card)) === card.value()
            @test isassigned(card) === false
            @test isinteger(card) === false
            @test isreal(card) === false
            # Convert callable value object by calling the object itself.
            @test card.value(valtype(card)) === card.value()
            @test_throws Exception card.value(Bool)
            @test_throws Exception card.value(Int16)
            @test_throws Exception card.value(Integer)
            @test_throws Exception card.value(Real)
            @test_throws Exception card.value(AbstractFloat)
            @test_throws Exception card.value(Complex)
            @test_throws Exception card.value(String)
            @test_throws Exception card.value(AbstractString)
            # Convert callable value object by calling `convert`.
            @test convert(valtype(card), card.value) === card.value()
            @test_throws Exception convert(Bool,           card.value)
            @test_throws Exception convert(Int16,          card.value)
            @test_throws Exception convert(Integer,        card.value)
            @test_throws Exception convert(Real,           card.value)
            @test_throws Exception convert(AbstractFloat,  card.value)
            @test_throws Exception convert(Complex,        card.value)
            @test_throws Exception convert(String,         card.value)
            @test_throws Exception convert(AbstractString, card.value)
            # Various string representations.
            @test repr(card) isa String
            @test repr("text/plain", card) isa String
            @test repr(card.value) isa String
            @test repr("text/plain", card.value) isa String
            # is_comment(), is_end(), ...
            @test is_comment(card) === true
            @test is_comment(card.type) === true
            @test is_comment(card.key) === true # standard comment
            @test is_end(card) === false
            @test is_end(card.type) === false
            @test is_end(card.key) === false
            @test is_structural(card) == false
            @test is_naxis(card) == false
        end
        let card = FitsCard("HISTORY A new history starts here...                                     ")
            @test card.type == FITS_COMMENT
            @test card.key == Fits"HISTORY"
            @test card.name == "HISTORY"
            @test card.comment == "A new history starts here..."
            @test card.value() isa Nothing
            @test card.value() === nothing
            @test valtype(card) === typeof(card.value())
            @test card.value(valtype(card)) === card.value()
            @test isassigned(card) === false
            @test isinteger(card) === false
            @test isreal(card) === false
            # Convert callable value object by calling the object itself.
            @test card.value(valtype(card)) === card.value()
            @test_throws Exception card.value(Bool)
            @test_throws Exception card.value(Int16)
            @test_throws Exception card.value(Integer)
            @test_throws Exception card.value(Real)
            @test_throws Exception card.value(AbstractFloat)
            @test_throws Exception card.value(Complex)
            @test_throws Exception card.value(String)
            @test_throws Exception card.value(AbstractString)
            # Convert callable value object by calling `convert`.
            @test convert(valtype(card), card.value) === card.value()
            @test_throws Exception convert(Bool,           card.value)
            @test_throws Exception convert(Int16,          card.value)
            @test_throws Exception convert(Integer,        card.value)
            @test_throws Exception convert(Real,           card.value)
            @test_throws Exception convert(AbstractFloat,  card.value)
            @test_throws Exception convert(Complex,        card.value)
            @test_throws Exception convert(String,         card.value)
            @test_throws Exception convert(AbstractString, card.value)
            # Various string representations.
            @test repr(card) isa String
            @test repr("text/plain", card) isa String
            @test repr(card.value) isa String
            @test repr("text/plain", card.value) isa String
            # is_comment(), is_end(), ...
            @test is_comment(card) === true
            @test is_comment(card.type) === true
            @test is_comment(card.key) === true # standard comment
            @test is_end(card) === false
            @test is_end(card.type) === false
            @test is_end(card.key) === false
            @test is_structural(card) == false
            @test is_naxis(card) == false
        end
        # Non standard commentary card.
        let card = FitsCard("NON-STANDARD COMMENT" => (nothing, "some comment"))
            @test card.type == FITS_COMMENT
            @test card.key == Fits"HIERARCH"
            @test card.name == "HIERARCH NON-STANDARD COMMENT"
            @test card.comment == "some comment"
            @test card.value() isa Nothing
            @test card.value() === nothing
            @test valtype(card) === typeof(card.value())
            @test card.value(valtype(card)) === card.value()
            @test isassigned(card) === false
            @test isinteger(card) === false
            @test isreal(card) === false
            # Convert callable value object by calling the object itself.
            @test card.value(valtype(card)) === card.value()
            @test_throws Exception card.value(Bool)
            @test_throws Exception card.value(Int16)
            @test_throws Exception card.value(Integer)
            @test_throws Exception card.value(Real)
            @test_throws Exception card.value(AbstractFloat)
            @test_throws Exception card.value(Complex)
            @test_throws Exception card.value(String)
            @test_throws Exception card.value(AbstractString)
            # Convert callable value object by calling `convert`.
            @test convert(valtype(card), card.value) === card.value()
            @test_throws Exception convert(Bool,           card.value)
            @test_throws Exception convert(Int16,          card.value)
            @test_throws Exception convert(Integer,        card.value)
            @test_throws Exception convert(Real,           card.value)
            @test_throws Exception convert(AbstractFloat,  card.value)
            @test_throws Exception convert(Complex,        card.value)
            @test_throws Exception convert(String,         card.value)
            @test_throws Exception convert(AbstractString, card.value)
            # Various string representations.
            @test repr(card) isa String
            @test repr("text/plain", card) isa String
            @test repr(card.value) isa String
            @test repr("text/plain", card.value) isa String
            # is_comment(), is_end(), ...
            @test is_comment(card) === true
            @test is_comment(card.type) === true
            @test is_comment(card.key) === false # non-standard comment
            @test is_end(card) === false
            @test is_end(card.type) === false
            @test is_end(card.key) === false
            @test is_structural(card) == false
            @test is_naxis(card) == false
        end
        # String valued card.
        let card = FitsCard("REMARK  = 'Joe''s taxi'        / a string with an embedded quote         ")
            @test card.type == FITS_STRING
            @test card.key == Fits"REMARK"
            @test card.name == "REMARK"
            @test card.comment == "a string with an embedded quote"
            @test card.value() isa String
            @test card.value() == "Joe's taxi"
            @test card.value() === card.string
            @test valtype(card) === typeof(card.value())
            @test card.value(valtype(card)) === card.value()
            @test repr(card) isa String
            @test repr("text/plain", card) isa String
            @test repr(card.value) isa String
            @test repr("text/plain", card.value) isa String
            @test isassigned(card) === true
            @test isinteger(card) === false
            @test isreal(card) === false

            # Convert callable value object by calling the object itself.
            @test card.value(valtype(card)) === card.value()
            @test_throws Exception card.value(Bool)
            @test_throws Exception card.value(Int16)
            @test_throws Exception card.value(Integer)
            @test_throws Exception card.value(Real)
            @test_throws Exception card.value(AbstractFloat)
            @test_throws Exception card.value(Complex)
            @test card.value(String)         === convert(String,         card.value())
            @test card.value(AbstractString) === convert(AbstractString, card.value())
            # Convert callable value object by calling `convert`.
            @test convert(valtype(card), card.value) === card.value()
            @test_throws Exception convert(Bool,           card.value)
            @test_throws Exception convert(Int16,          card.value)
            @test_throws Exception convert(Integer,        card.value)
            @test_throws Exception convert(Real,           card.value)
            @test_throws Exception convert(AbstractFloat,  card.value)
            @test_throws Exception convert(Complex,        card.value)
            @test convert(String,         card.value) === card.value(String)
            @test convert(AbstractString, card.value) === card.value(AbstractString)
            # Various string representations.
            @test repr(card) isa String
            @test repr("text/plain", card) isa String
            @test repr(card.value) isa String
            @test repr("text/plain", card.value) isa String
             # is_comment(), is_end(), ...
            @test is_comment(card) == false
            @test is_comment(card.type) == false
            @test is_comment(card.key) == false
            @test is_end(card) == false
            @test is_end(card.type) == false
            @test is_end(card.key) == false
            @test is_structural(card) == false
            @test is_naxis(card) == false
        end
        #
        let card = FitsCard("EXTNAME = 'SCIDATA ' ")
            @test card.type == FITS_STRING
            @test card.key == Fits"EXTNAME"
            @test card.name == "EXTNAME"
            @test card.comment == ""
            @test isinteger(card) === false
            @test isassigned(card) === true
            @test card.value() isa String
            @test card.value() == "SCIDATA"
            @test card.value() === card.string
            @test valtype(card) === typeof(card.value())
            @test card.value(valtype(card)) === card.value()
            @test repr(card) isa String
            @test repr("text/plain", card) isa String
            @test repr(card.value) isa String
            @test repr("text/plain", card.value) isa String
            @test isassigned(card) === true
            @test isinteger(card) === false
            @test isreal(card) === false
        end
        #
        let card = FitsCard("CRPIX1  =                   1. ")
            @test card.type == FITS_FLOAT
            @test card.key == Fits"CRPIX1"
            @test card.name == "CRPIX1"
            @test card.comment == ""
            @test card.value() isa FitsFloat
            @test card.value() ≈ 1.0
            @test card.value() === card.float
            @test valtype(card) === typeof(card.value())
            @test card.value(valtype(card)) === card.value()
            @test repr(card) isa String
            @test repr("text/plain", card) isa String
            @test repr(card.value) isa String
            @test repr("text/plain", card.value) isa String
            @test isassigned(card) === true
            @test isinteger(card) === false
            @test isreal(card) === true
        end
        #
        let card = FitsCard("CRVAL3  =                 0.96 / CRVAL along 3rd axis ")
            @test card.type == FITS_FLOAT
            @test card.key == Fits"CRVAL3"
            @test card.name == "CRVAL3"
            @test card.comment == "CRVAL along 3rd axis"
            @test card.value() isa FitsFloat
            @test card.value() ≈ 0.96
            @test card.value() === card.float
            @test valtype(card) === typeof(card.value())
            @test card.value(valtype(card)) === card.value()
            @test repr(card) isa String
            @test repr("text/plain", card) isa String
            @test repr(card.value) isa String
            @test repr("text/plain", card.value) isa String
            @test isassigned(card) === true
            @test isinteger(card) === false
            @test isreal(card) === true
        end
        #
        let card = FitsCard("HIERARCH ESO OBS EXECTIME = +2919 / Expected execution time ")
            @test card.type == FITS_INTEGER
            @test card.key == Fits"HIERARCH"
            @test card.name == "HIERARCH ESO OBS EXECTIME"
            @test card.comment == "Expected execution time"
            @test card.value() isa FitsInteger
            @test card.value() == +2919
            @test card.value() === card.integer
            @test valtype(card) === typeof(card.value())
            @test card.value(valtype(card)) === card.value()
            @test repr(card) isa String
            @test repr("text/plain", card) isa String
            @test repr(card.value) isa String
            @test repr("text/plain", card.value) isa String
            @test isassigned(card) === true
            @test isinteger(card) === true
            @test isreal(card) === true
        end
        # FITS cards with undefined value.
        let card = FitsCard("DUMMY   =                        / no value given ")
            @test card.type == FITS_UNDEFINED
            @test card.key == Fits"DUMMY"
            @test card.name == "DUMMY"
            @test card.comment == "no value given"
            @test card.value() === undef
            @test valtype(card) === typeof(card.value())
            @test card.value(valtype(card)) === card.value()
            @test repr(card) isa String
            @test repr("text/plain", card) isa String
            @test repr(card.value) isa String
            @test repr("text/plain", card.value) isa String
            @test isassigned(card) === false
            @test isinteger(card) === false
            @test isreal(card) === false
        end
        let card = FitsCard("HIERARCH DUMMY   =               / no value given ")
            @test card.type == FITS_UNDEFINED
            @test card.key == Fits"HIERARCH"
            @test card.name == "HIERARCH DUMMY"
            @test card.comment == "no value given"
            @test card.value() === undef
            @test valtype(card) === typeof(card.value())
            @test card.value(valtype(card)) === card.value()
            @test repr(card) isa String
            @test repr("text/plain", card) isa String
            @test repr(card.value) isa String
            @test repr("text/plain", card.value) isa String
            @test isassigned(card) === false
            @test isinteger(card) === false
            @test isreal(card) === false
        end
        # Complex valued cards.
        let card = FitsCard("COMPLEX = (1,0)                  / [km/s] some complex value ")
            @test card.type == FITS_COMPLEX
            @test card.key == Fits"COMPLEX"
            @test card.name == "COMPLEX"
            @test card.comment == "[km/s] some complex value"
            @test card.units == "km/s"
            @test card.unitless == "some complex value"
            @test card.value() isa FitsComplex
            @test card.value() ≈ complex(1,0)
            @test valtype(card) === typeof(card.value())
            @test card.value(valtype(card)) === card.value()
            @test repr(card) isa String
            @test repr("text/plain", card) isa String
            @test repr(card.value) isa String
            @test repr("text/plain", card.value) isa String
            @test isassigned(card) === true
            @test isinteger(card) === false
            @test isreal(card) === iszero(imag(card.value()))
        end
        let card = FitsCard("COMPLEX = (-2.7,+3.1d5)          / some other complex value ")
            @test card.type == FITS_COMPLEX
            @test card.key == Fits"COMPLEX"
            @test card.name == "COMPLEX"
            @test card.comment == "some other complex value"
            @test card.value() isa FitsComplex
            @test card.value() ≈ complex(-2.7,+3.1e5)
            @test valtype(card) === typeof(card.value())
            @test card.value(valtype(card)) === card.value()
            @test repr(card) isa String
            @test repr("text/plain", card) isa String
            @test repr(card.value) isa String
            @test repr("text/plain", card.value) isa String
            @test card.value(Complex{Float32}) === Complex{Float32}(card.value())
            @test convert(Complex{Float32}, card.value) === Complex{Float32}(card.value())
            @test_throws InexactError card.value(Float64)
            @test_throws InexactError convert(Float32, card.value)
            @test isassigned(card) === true
            @test isinteger(card) === false
            @test isreal(card) === iszero(imag(card.value()))
        end
        # END card.
        let card = FitsCard("END                           ")
            @test card.type == FITS_END
            @test card.key == Fits"END"
            @test card.name == "END"
            @test card.comment == ""
            @test card.value() isa Nothing
            @test card.value() === nothing
            @test valtype(card) === typeof(card.value())
            @test card.value(valtype(card)) === card.value()
            @test repr(card) isa String
            @test repr("text/plain", card) isa String
            @test repr(card.value) isa String
            @test repr("text/plain", card.value) isa String
            @test isassigned(card) === false
            @test isinteger(card) === false
            @test isreal(card) === false
            @test is_comment(card) == false
            @test is_comment(card.type) == false
            @test is_comment(card.key) == false
            @test is_end(card) == true
            @test is_end(card.type) == true
            @test is_end(card.key) == true
            @test is_structural(card) == true
            @test is_naxis(card) == false
        end
    end
    @testset "Cards from bytes" begin
        # Logical FITS cards.
        str = "SIMPLE  =                    T / this is a FITS file                            "
        for buf in (make_byte_vector(str), make_discontinuous_byte_vector(str))
            card = FitsCard(buf)
                        @test card.type == FITS_LOGICAL
            @test card.key == Fits"SIMPLE"
            @test card.name == "SIMPLE"
            @test card.comment == "this is a FITS file"
            @test card.value() isa Bool
            @test card.value() == true
            @test card.value() === card.logical
            @test valtype(card) === typeof(card.value())
        end
        # "END", empty string "" or out of range offset yield an END card.
        let card = FitsCard("END")
            @test card.type === FITS_END
            @test card.key === Fits"END"
        end
        let card = FitsCard("")
            @test card.type === FITS_END
            @test card.key === Fits"END"
        end
        let card = FitsCard("xEND"; offset=1)
            @test card.type === FITS_END
            @test card.key === Fits"END"
        end
        let card = FitsCard("SOMETHING"; offset=250)
            @test card.type === FITS_END
            @test card.key === Fits"END"
        end
    end
    @testset "Cards from pairs" begin
        # Badly formed cards.
        @test_throws ArgumentError FitsCard(:GIZMO => [])
        @test_throws ArgumentError FitsCard("GIZMO" => ("comment",2))
        # Well formed cards and invariants.
        @test FitsCard(:GIZMO => 1) isa FitsCard
        @test FitsCard(:GIZMO => 1).type === FITS_INTEGER
        @test FitsCard(:GIZMO => 1) === FitsCard("GIZMO" => 1)
        @test FitsCard(:GIZMO => 1) === FitsCard("GIZMO" => (1,))
        @test FitsCard(:GIZMO => 1) === FitsCard("GIZMO" => (1,nothing))
        @test FitsCard(:GIZMO => 1) === FitsCard("GIZMO" => (1,""))
        @test FitsCard(:COMMENT => "Hello world!") isa FitsCard
        @test FitsCard(:COMMENT => "Hello world!").type === FITS_COMMENT
        @test FitsCard(:COMMENT => "Hello world!") === FitsCard("COMMENT" => "Hello world!")
        @test FitsCard(:COMMENT => "Hello world!") === FitsCard("COMMENT" => (nothing, "Hello world!"))
        # Logical FITS cards.
        com = "some comment"
        pair = "SIMPLE" => (true, com)
        card = FitsCard(pair)
        @test FitsCard(card) === card
        @test convert(FitsCard, card) === card
        @test convert(FitsCard, pair) == card
        @test convert(Pair, card) == pair
        @test Pair(card) == pair
        @test Pair{String}(card) === pair
        @test Pair{String,Tuple{Bool,String}}(card) === pair
        @test Pair{String,Tuple{Int,String}}(card) === (card.name => (card.value(Int), card.comment))
        @test card.type === FITS_LOGICAL
        @test card.key === Fits"SIMPLE"
        @test card.name === "SIMPLE"
        @test card.value() === true
        @test card.comment == com
        @test_throws ErrorException card.value(FitsCard)
        card = FitsCard("TWO KEYS" => (π, com))
        @test card.type === FITS_FLOAT
        @test card.key === Fits"HIERARCH"
        @test card.name == "HIERARCH TWO KEYS"
        @test card.value() ≈ π
        @test card.comment == com
        card = convert(FitsCard, "HIERARCH NAME" => ("some name", com))
        @test card.type === FITS_STRING
        @test card.key === Fits"HIERARCH"
        @test card.name == "HIERARCH NAME"
        @test card.value() == "some name"
        @test card.comment == com
        card = convert(FitsCard, "HIERARCH COMMENT" => (nothing, com))
        @test card.type === FITS_COMMENT
        @test card.key === Fits"HIERARCH"
        @test card.name == "HIERARCH COMMENT"
        @test card.value() === nothing
        @test card.comment == com
        card = convert(FitsCard, "COMMENT" => com)
        @test card.type === FITS_COMMENT
        @test card.key === Fits"COMMENT"
        @test card.name == "COMMENT"
        @test card.value() === nothing
        @test card.comment == com
        card = convert(FitsCard, "REASON" => undef)
        @test card.type === FITS_UNDEFINED
        @test card.key === Fits"REASON"
        @test card.name == "REASON"
        @test card.value() === undef
        @test card.comment == ""
        card = convert(FitsCard, "REASON" => (missing, com))
        @test card.type === FITS_UNDEFINED
        @test card.key === Fits"REASON"
        @test card.name == "REASON"
        @test card.value() === undef
        @test card.comment == com
        # Dates.
        date = now()
        card = FitsCard("DATE-OBS" => date)
        @test card.type === FITS_STRING
        @test card.key === Fits"DATE-OBS"
        @test card.name == "DATE-OBS"
        @test card.value() == Dates.format(date, ISODateTimeFormat)
        @test card.value(DateTime) === date
        @test convert(DateTime, card.value) === date
        @test DateTime(card.value) === date
        @test card.comment == ""
        card = FitsCard("DATE-OBS" => (date))
        @test card.type === FITS_STRING
        @test card.key === Fits"DATE-OBS"
        @test card.name == "DATE-OBS"
        @test card.value() == Dates.format(date, ISODateTimeFormat)
        @test card.value(DateTime) === date
        @test convert(DateTime, card.value) === date
        @test DateTime(card.value) === date
        @test card.comment == ""
        card = FitsCard("DATE-OBS" => (date, com))
        @test card.type === FITS_STRING
        @test card.key === Fits"DATE-OBS"
        @test card.name == "DATE-OBS"
        @test card.value() == Dates.format(date, ISODateTimeFormat)
        @test card.value(DateTime) === date
        @test convert(DateTime, card.value) === date
        @test DateTime(card.value) === date
        @test card.comment == com
    end
    @testset "Operations on card values" begin
        A = FitsCard("KEY_A" => true).value
        B = FitsCard("KEY_B" => 42).value
        C = FitsCard("KEY_C" => 24.0).value
        D = FitsCard("KEY_D" => "hello").value
        @test A == A()
        @test A() == A
        @test A == true
        @test A != false
        @test A > false
        @test A ≥ true
        @test A ≤ true

        @test B == B()
        @test B() == B
        @test B == 42
        @test B != 41
        @test B > Int16(41)
        @test B ≥ Int16(42)
        @test B ≤ Int16(42)

        @test C == C()
        @test C() == C
        @test C == C
        @test C == 24
        @test C != 25
        @test C > 23
        @test C ≥ 24
        @test C ≤ 24

        @test D == D()
        @test D() == D
        @test D == "hello"
        @test D != "Hello"

        @test A == A
        @test A != B
        @test A != C
        @test A != D

        @test B != A
        @test B == B
        @test B != C
        @test B != D

        @test C != A
        @test C != B
        @test C == C
        @test C != D

        @test D != A
        @test D != B
        @test D != C
        @test D == D

        @test B > A
        @test B ≥ A
        @test B > C
        @test B ≥ C
    end
    @testset "Headers" begin
        dims = (4,5,6,7)
        h = FitsHeader("SIMPLE" => (true, "FITS file"),
                       "BITPIX" => (-32, "bits per pixels"),
                       "NAXIS" => (length(dims), "number of dimensions"))
        @test length(h) == 3
        @test sort(collect(keys(h))) == ["BITPIX", "NAXIS", "SIMPLE"]
        # Same object:
        @test convert(FitsHeader, h) === h
        # Same contents but different objects:
        hp = convert(FitsHeader, h.cards); @test hp !== h && hp == h
        hp = FitsHeader(h); @test  hp !== h && hp == h
        hp = copy(h); @test  hp !== h && hp == h
        @test length(empty!(hp)) == 0
        @test  haskey(h, "NAXIS")
        @test !haskey(h, "NO-SUCH-KEY")
        @test  haskey(h, firstindex(h))
        @test !haskey(h, lastindex(h) + 1)
        @test get(h, "NAXIS", π) isa FitsCard
        @test get(h, "illegal keyword!", π) === π
        @test get(h, +, π) === π
        @test getkey(h, "illegal keyword!", π) === π
        @test getkey(h, "NAXIS", π) == "NAXIS"
        @test IndexStyle(h) === IndexLinear()
        @test h["SIMPLE"] === h[1]
        @test h[1].key === Fits"SIMPLE"
        @test h[1].value() == true
        @test h["BITPIX"] === h[2]
        @test h[2].key === Fits"BITPIX"
        @test h[2].value() == -32
        @test h["NAXIS"] === h[3]
        @test h[3].key === Fits"NAXIS"
        @test h[3].value() == length(dims)
        # Build 2 another headers, one with just the dimensions, the other with
        # some other records, then merge these headers.
        h1 = FitsHeader(h["NAXIS"])
        for i in eachindex(dims)
            push!(h1, "NAXIS$i" => (dims[i], "length of dimension # $i"))
        end
        h2 = FitsHeader(COMMENT = "Some comment.",
                        BSCALE = (1.0, "Scaling factor."),
                        BZERO = (0.0, "Bias offset."))
        h2["CCD GAIN"] = (3.2, "[ADU/e-] detector gain")
        h2["HIERARCH CCD BIAS"] = -15
        h2["COMMENT"] = "Another comment."
        h2["COMMENT"] = "Yet another comment."
        @test merge!(h) === h
        hp = merge(h, h1, h2)
        @test merge!(h, h1, h2) === h
        @test hp == h && hp !== h
        @test merge!(hp, h1) == h # re-merging existing unique cards does not change anything
        empty!(h1)
        empty!(h2)
        empty!(hp)
        @test length(eachmatch("COMMENT", h)) == 3
        @test count(Returns(true), eachmatch("COMMENT", h)) == 3
        coms = collect("COMMENT", h)
        @test length(coms) == 3
        @test coms isa Vector{FitsCard}
        @test coms[1].comment == "Some comment."
        @test coms[2].comment == "Another comment."
        @test coms[3].comment == "Yet another comment."
        iter = eachmatch("COMMENT", h)
        @test reverse(reverse(iter)) === iter
        @test collect(iter) == coms
        @test collect(reverse(iter)) == reverse(coms)
        # Test indexing by integer/name.
        i = findfirst("BITPIX", h)
        @test i isa Integer && h[i].name == "BITPIX"
        @test h["BITPIX"] === h[i]
        @test h["BSCALE"].value(Real) ≈ 1
        @test h["BSCALE"].comment == "Scaling factor."
        # Test HIERARCH records.
        @test get(h, 0, nothing) === nothing
        @test get(h, 1, nothing) === h[1]
        card = get(h, "HIERARCH CCD GAIN", nothing)
        @test card isa FitsCard
        if card !== Nothing
            @test card.key === Fits"HIERARCH"
            @test card.name == "HIERARCH CCD GAIN"
            @test card.value() ≈ 3.2
            @test card.units == "ADU/e-"
            @test card.unitless == "detector gain"
        end
        card = get(h, "CCD BIAS", nothing)
        @test card isa FitsCard
        if card !== Nothing
            @test card.key === Fits"HIERARCH"
            @test card.name == "HIERARCH CCD BIAS"
            @test card.value() == -15
        end
        # Change existing record, by name and by index for a short and for a
        # HIERARCH keyword.
        n = length(h)
        h["BSCALE"] = (1.1, "better value")
        @test length(h) == n
        @test h["BSCALE"].value(Real) ≈ 1.1
        @test h["BSCALE"].comment == "better value"
        i = findfirst("BITPIX", h)
        @test i isa Integer
        h[i] = (h[i].name => (-64, h[i].comment))
        @test h["BITPIX"].value() == -64
        i = findfirst("CCD BIAS", h)
        h[i] = ("CCD LOW BIAS" => (h[i].value(), h[i].comment))
        @test h[i].name == "HIERARCH CCD LOW BIAS"
        # It is forbidden to have more than one non-unique keyword.
        i = findfirst("BITPIX", h)
        @test_throws ArgumentError h[i+1] = h[i]
        # Replace a card by comment appering earlier than any other comment. Do
        # this in a temporary copy to avoid corrupting the header.
        let hp = copy(h)
            n = length(eachmatch("COMMENT", hp))
            i = findfirst("COMMENT", hp)
            hp[i-1] = ("COMMENT" => (nothing, "Some early comment."))
            @test findfirst("COMMENT", hp) == i - 1
            @test length(eachmatch("COMMENT", hp)) == n + 1
            @test hp[i-1].type == FITS_COMMENT
        end
        # Replace existing card by another one with another name. Peek the
        # first of a non-unique record to check that the index is correctly
        # updated.
        for i in 1:3 # we need a number of commentary records
            h["HISTORY"] = "History record number $i."
            h["OTHER$i"] = (i, "Something else.")
            if i == 1
                # Check findlast/findfirst on a commentary keyword that has a
                # single occurence.
                @test findlast("HISTORY", h) == length(h) - 1
                @test findfirst("HISTORY", h) == length(h) - 1
            end
        end
        n = length(eachmatch("HISTORY", h))
        @test n ≥ 3
        while n > 0
            i = findfirst("HISTORY", h)
            @test i isa Integer
            h[i] = ("SOME$i" => (42, h[i].comment))
            n -= 1
            @test length(eachmatch("HISTORY", h)) == n
        end
        @test findfirst("HISTORY", h) === nothing
        # Append non-existing record.
        n = length(h)
        h["GIZMO"] = ("Joe's taxi", "what?")
        @test length(h) == n+1
        @test h["GIZMO"].value() == "Joe's taxi"
        @test h["GIZMO"].comment == "what?"
        # Test search failure when: (i) keyword is valid but does not exists,
        # (ii) keyword is invalid, and (iii) pattern is unsupported.
        @test findfirst("NON-EXISTING KEYWORD", h) === nothing
        @test findfirst("Invalid keyword", h) === nothing
        @test findfirst(π, h) === nothing
        @test findfirst(π, h) === nothing
        @test findlast(π, h) === nothing
        @test findnext(π, h, firstindex(h)) === nothing
        @test findprev(π, h, lastindex(h)) === nothing
        @test_throws BoundsError findnext(π, h, firstindex(h) - 1)
        @test_throws BoundsError findprev(π, h, lastindex(h) + 1)
        @test_throws BoundsError findnext("SIMPLE", h, firstindex(h) - 1)
        @test_throws BoundsError findprev("SIMPLE", h, lastindex(h) + 1)
        @test findnext(π, h, lastindex(h) + 1) === nothing
        @test findprev(π, h, firstindex(h) - 1) === nothing
        @test findnext("SIMPLE", h, lastindex(h) + 1) === nothing
        @test findprev("SIMPLE", h, firstindex(h) - 1) === nothing
        # Forward search.
        i = findfirst("COMMENT", h)
        @test i isa Integer
        @test h[i].type === FITS_COMMENT
        @test h[i].comment == "Some comment."
        i = findnext(h[i], h, i + 1)
        @test i isa Integer
        @test h[i].type === FITS_COMMENT
        @test h[i].comment == "Another comment."
        i = findnext(h[i], h, i + 1)
        @test i isa Integer
        @test h[i].type === FITS_COMMENT
        @test h[i].comment == "Yet another comment."
        @test findnext(h[i], h, i + 1) isa Nothing
        # Backward search.
        i = findlast("COMMENT", h)
        @test i isa Integer
        @test h[i].type === FITS_COMMENT
        @test h[i].comment == "Yet another comment."
        i = findprev("COMMENT", h, i - 1)
        @test i isa Integer
        @test h[i].type === FITS_COMMENT
        @test h[i].comment == "Another comment."
        i = findprev(h[i], h, i - 1)
        @test i isa Integer
        @test h[i].type === FITS_COMMENT
        @test h[i].comment == "Some comment."
        @test findprev(h[i], h, i - 1) isa Nothing
        # Check that non-commentary records are unique.
        for i in eachindex(h)
            card = h[i]
            card.type === FITS_COMMENT && continue
            @test findnext(card, h, i + 1) isa Nothing
        end
        # Search with a predicate.
        @test findfirst(card -> card.type === FITS_END, h) === nothing
        @test findlast(card -> card.name == "BITPIX", h) === 2
        # Apply a filter.
        hp = filter(card -> match(r"^NAXIS[0-9]*$", card.name) !== nothing, h)
        @test hp isa FitsHeader
        @test startswith(first(hp).name, "NAXIS")
        @test startswith(last(hp).name, "NAXIS")
        # Search by regular expressions.
        n = length(dims)
        pat = r"^NAXIS[0-9]*$"
        i = findfirst(pat, h)
        @test h[i].name == "NAXIS"
        i = findnext(pat, h, i+1)
        @test h[i].name == "NAXIS1"
        i = findnext(pat, h, i+1)
        @test h[i].name == "NAXIS2"
        i = findlast(pat, h)
        @test h[i].name == "NAXIS$(n)"
        i = findprev(pat, h, i-1)
        @test h[i].name == "NAXIS$(n - 1)"
        i = findnext(pat, h, i-1)
        @test h[i].name == "NAXIS$(n - 2)"
        let hp = filter(pat, h)
            @test hp isa FitsHeader
            @test startswith(first(hp).name, "NAXIS")
            @test startswith(last(hp).name, "NAXIS")
        end
        let v = collect(pat, h)
            @test v isa Vector{FitsCard}
            @test startswith(first(v).name, "NAXIS")
            @test startswith(last(v).name, "NAXIS")
        end
    end
end

end # module
