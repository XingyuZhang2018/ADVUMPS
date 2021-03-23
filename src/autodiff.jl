using Zygote
using LinearAlgebra

# patch since it's currently broken otherwise
@Zygote.adjoint function Base.typed_hvcat(::Type{T}, rows::Tuple{Vararg{Int}}, xs::S...) where {T,S}
  Base.typed_hvcat(T,rows, xs...), ȳ -> (nothing, nothing, permutedims(ȳ)...)
end

@doc raw"
    num_grad(f, K::Real; [δ = 1e-5])

return the numerical gradient of `f` at `K` calculated with
`(f(K+δ/2) - f(K-δ/2))/δ`

# example

```jldoctest; setup = :(using TensorNetworkAD)
julia> TensorNetworkAD.num_grad(x -> x * x, 3) ≈ 6
true
```
"
num_grad(f, K::Real; δ::Real = 1e-5) = (f(K+δ/2) - f(K-δ/2))/δ

@doc raw"
    num_grad(f, K::AbstractArray; [δ = 1e-5])
    
return the numerical gradient of `f` for each element of `K`.

# example

```jldoctest; setup = :(using TensorNetworkAD, LinearAlgebra)
julia> TensorNetworkAD.num_grad(tr, rand(2,2)) ≈ I
true
```
"
function num_grad(f, a::AbstractArray; δ::Real = 1e-5)
    map(CartesianIndices(a)) do i
        foo = x -> (ac = copy(a); ac[i] = x; f(ac))
        num_grad(foo, a[i], δ = δ)
    end
end