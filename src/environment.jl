using LinearAlgebra
using KrylovKit

"""
tensor order graph: from left to right, top to bottom.
```
a ────┬──── c    a──────┬──────c   
│     b     │    │      │      │                     
├─ d ─┼─ e ─┤    │      b      │                  
│     g     │    │      │      │  
f ────┴──── h    d──────┴──────e    
```
"""

safesign(x::Number) = iszero(x) ? one(x) : sign(x)

"""
    qrpos(A)

Returns a QR decomposition, i.e. an isometric `Q` and upper triangular `R` matrix, where `R`
is guaranteed to have positive diagonal elements.
"""
qrpos(A) = qrpos!(copy(A))
function qrpos!(A)
    mattype = _mattype(A)
    F = qr!(mattype(A))
    Q = mattype(F.Q)
    R = F.R
    phases = safesign.(diag(R))
    rmul!(Q, Diagonal(phases))
    lmul!(Diagonal(conj!(phases)), R)
    return Q, R
end

"""
    lqpos(A)

Returns a LQ decomposition, i.e. a lower triangular `L` and isometric `Q` matrix, where `L`
is guaranteed to have positive diagonal elements.
"""
lqpos(A) = lqpos!(copy(A))
function lqpos!(A)
    mattype = _mattype(A)
    F = qr!(mattype(A'))
    Q = mattype(mattype(F.Q)')
    L = mattype(F.R')
    phases = safesign.(diag(L))
    lmul!(Diagonal(phases), Q)
    rmul!(L, Diagonal(conj!(phases)))
    return L, Q
end

function mysvd(A)
    svd(A)
end

"""
    leftorth(A, [C]; kwargs...)

Given an MPS tensor `A`, return a left-canonical MPS tensor `AL`, a gauge transform `C` and
a scalar factor `λ` such that ``λ AL^s C = C A^s``, where an initial guess for `C` can be
provided.
```
    ┌─AL─      ┌──      a───┬───c  
    │ │     =  │        │   b   │          
    ┕─AL─      ┕──      d───┴───e                          
```
"""
function leftorth(A, C = _mattype(A){eltype(A)}(I, size(A,1), size(A,1)); tol = 1e-12, maxiter = 100, kwargs...)
    _, ρs, info = eigsolve(C'*C, 1, :LM; ishermitian = false, tol = tol, maxiter = 1, kwargs...) do ρ
        ρE = ein"(da,abc),dbe -> ec"(ρ, A, conj(A))
        return ρE
    end
    ρ = ρs[1] + ρs[1]'
    ρ ./= tr(ρ)
    # C = cholesky!(ρ).U
    # If ρ is not exactly positive definite, cholesky will fail
    F = svd!(ρ)
    C = lmul!(Diagonal(sqrt.(F.S)), F.Vt)
    _, C = qrpos!(C)

    D, d, = size(A)
    Q, R = qrpos!(reshape(C*reshape(A, D, d*D), D*d, D))
    AL = reshape(Q, D, d, D)
    λ = norm(R)
    rmul!(R, 1/λ)
    numiter = 1
    while norm(C-R) > tol && numiter < maxiter
        # C = R
        _, Cs, info = eigsolve(R, 1, :LM; ishermitian = false, tol = tol, maxiter = maxiter, kwargs...) do X
            Y = ein"(da,abc),dbe -> ec"(X,A,conj(AL))
            return Y
        end
        _, C = qrpos!(Cs[1])
        # The previous lines can speed up the process when C is still very far from the correct
        # gauge transform, it finds an improved value of C by finding the fixed point of a
        # 'mixed' transfer matrix composed of `A` and `AL`, even though `AL` is also still not
        # entirely correct. Therefore, we restrict the number of iterations to be 1 and don't
        # check for convergence
        Q, R = qrpos!(reshape(C*reshape(A, D, d*D), D*d, D))
        AL = reshape(Q, D, d, D)
        λ = norm(R)
        rmul!(R, 1/λ)
        numiter += 1
    end
    C = R
    return AL, C, λ
end

"""
    rightorth(A, [C]; kwargs...)

Given an MPS tensor `A`, return a gauge transform C, a right-canonical MPS tensor `AR`, and
a scalar factor `λ` such that `λ C AR^s = A^s C`, where an initial guess for `C` can be
provided.
````
    ─ AR─┐     ──┐  
      │  │  =    │  
    ─ AR─┘     ──┘  
````
"""
function rightorth(A, C = _mattype(A){eltype(A)}(I, size(A,1), size(A,1)); tol = 1e-12, maxiter = 100, kwargs...)
    AL, C, λ = leftorth(permutedims(A,(3,2,1)), permutedims(C,(2,1)); tol = tol, maxiter = maxiter, kwargs...)
    return permutedims(C,(2,1)), permutedims(AL,(3,2,1)), λ
end

"""
    λ, FL = leftenv(ALu, ALd, M, FL = _arraytype(ALu)(rand(eltype(ALu), size(ALu,1), size(M,1), size(ALd,1))); kwargs...)

Compute the left environment tensor for MPS `AL` and MPO `M`, by finding the left fixed point
of `ALu - M - ALd` contracted along the physical dimension.
```
┌── ALu─       ┌──       a ────┬──── c 
│    │         │         │     b     │ 
FL ─ M ─  = λL FL─       ├─ d ─┼─ e ─┤ 
│    │         │         │     g     │ 
┕── ALd─       ┕──       f ────┴──── h 
```
"""

function leftenv(ALu, ALd, M, FL = _arraytype(ALu)(rand(eltype(ALu), size(ALu,1), size(M,1), size(ALd,1))); kwargs...)
    λs, FLs, info = eigsolve(FL -> ein"((adf,abc),dgeb),fgh -> ceh"(FL,ALu,M,conj(ALd)), FL, 1, :LM; ishermitian = false, kwargs...)
    if length(λs) > 1 && norm(abs(λs[1]) - abs(λs[2])) < 1e-12
        @show λs
        if real(λs[1]) > 0
            return real(λs[1]), real(FLs[1])
        else
            return real(λs[2]), real(FLs[2])
        end
    end
    # @show info,λs
    return λs[1], FLs[1]
end

"""
    λ, FR = rightenv(ARu, ARd, M, FR = _arraytype(ARu)(randn(eltype(ARu), size(ARu,3), size(M,3), size(ARd,3))); kwargs...)

Compute the right environment tensor for MPS `AR` and MPO `M`, by finding the right fixed point
of `ARu - M - ARd` contracted along the physical dimension.
```
 ─ ARu──┐         ──┐   
    │   │           │   
 ─  M ──FR   = λR ──FR  
    │   │           │   
 ─ ARd──┘         ──┘  
```
"""
function rightenv(ARu, ARd, M, FR = _arraytype(ARu)(randn(eltype(ARu), size(ARu,3), size(M,3), size(ARd,3))); kwargs...)
    ALu = permutedims(ARu,(3,2,1))
    ALd = permutedims(ARd,(3,2,1))
    ML = permutedims(M,(3,2,1,4))
    return leftenv(ALu, ALd, ML, FR; kwargs...)
end

"""
    λ, FL = obs_leftenv(ALu, ALd, M, FL = _arraytype(ALu)(rand(eltype(ALu), size(ALu,1), size(M,1), size(ALd,1))); kwargs...)

Compute the left environment tensor for MPS `AL` and MPO `M`, by finding the left fixed point
of `ALu - M - ALd` contracted along the physical dimension.
```
┌── ALu─       ┌──       a ────┬──── c 
│    │         │         │     b     │ 
FL ─ M ─  = λL FL─       ├─ d ─┼─ e ─┤ 
│    │         │         │     g     │ 
┕── ALd─       ┕──       f ────┴──── h 
```
"""

function obs_leftenv(ALu, ALd, M, FL = _arraytype(ALu)(rand(eltype(ALu), size(ALu,1), size(M,1), size(ALd,1))); kwargs...)
    λs, FLs, info = eigsolve(FL -> ein"((adf,abc),dgeb),fgh -> ceh"(FL,ALu,M,ALd), FL, 1, :LM; ishermitian = false, kwargs...)
    if length(λs) > 1 && norm(abs(λs[1]) - abs(λs[2])) < 1e-12
        @show λs
        if real(λs[1]) > 0
            return real(λs[1]), real(FLs[1])
        else
            return real(λs[2]), real(FLs[2])
        end
    end
    # @show info,λs
    return λs[1], FLs[1]
end

"""
    λ, FR = obs_rightenv(ARu, ARd, M, FR = _arraytype(ARu)(randn(eltype(ARu), size(ARu,3), size(M,3), size(ARd,3))); kwargs...)

Compute the right environment tensor for MPS `AR` and MPO `M`, by finding the right fixed point
of `ARu - M - ARd` contracted along the physical dimension.
```
 ─ ARu──┐         ──┐   
    │   │           │   
 ─  M ──FR   = λR ──FR  
    │   │           │   
 ─ ARd──┘         ──┘  
```
"""
function obs_rightenv(ARu, ARd, M, FR = _arraytype(ARu)(randn(eltype(ARu), size(ARu,3), size(M,3), size(ARd,3))); kwargs...)
    ALu = permutedims(ARu,(3,2,1))
    ALd = permutedims(ARd,(3,2,1))
    ML = permutedims(M,(3,2,1,4))
    return obs_leftenv(ALu, ALd, ML, FR; kwargs...)
end

"""
    λ, FL = norm_FL(ALu, ALd, FL; kwargs...)

Compute the left environment tensor for normalization, by finding the left fixed point
of `ALu - ALd` contracted along the physical dimension.
```
┌──ALu─      ┌──        a───┬───c   
FL  │  =  λL FL         │   b   │ 
┕──ALd─      ┕──        d───┴───e  
```
"""
function norm_FL(ALu, ALd, FL = _arraytype(ALu)(rand(eltype(ALu), size(ALu,1), size(ALd,1))); kwargs...)
    λs, FLs, info = eigsolve(FL -> ein"(ad,abc), dbe -> ce"(FL,ALu,conj(ALd)), FL, 1, :LM; ishermitian = false, kwargs...)
    return λs[1], FLs[1]
end

"""
    λ, FR = norm_FR(ARu, ARd, FR; kwargs...)

Compute the right environment tensor for normalization, by finding the right fixed point
of `ARu - ARd` contracted along the physical dimension.
```
 ─ AR──┐       ──┐   
   │   FR  = λR  FR   
 ─ AR──┘       ──┘ 
```
"""
function norm_FR(ARu, ARd, FR = _arraytype(ARu)(randn(eltype(ARu), size(ARu,3), size(ARd,3))); kwargs...)
    ALu = permutedims(ARu,(3,2,1))
    ALd = permutedims(ARd,(3,2,1))
    return norm_FL(ALu, ALd, FR; kwargs...)
end

"""
Compute the up environment tensor for MPS `FL`,`FR` and MPO `M`, by finding the up fixed point
    of `FL - M - FR` contracted along the physical dimension.
````
┌── AC──┐                          a ────┬──── c
│   │   │           ┌── AC──┐      │     b     │
FL─ M ──FR  =  λAC  │   │   │      ├─ d ─┼─ e ─┤
│   │   │                          │     g     │
                                   f ────┴──── h
````
"""
function ACenv(AC, FL, M, FR;kwargs...)
    λs, ACs, _ = eigsolve(AC -> ein"((adf,abc),dgeb),ceh -> fgh"(FL,AC,M,FR), AC, 1, :LM; ishermitian = false, kwargs...)
    if length(λs) > 1 && norm(abs(λs[1]) - abs(λs[2])) < 1e-12
        @show λs
        if real(λs[1]) > 0
            return real(λs[1]), real(ACs[1])
        else
            return real(λs[2]), real(ACs[2])
        end
    end
    # println("ACenv $(λs)") 
    return λs[1], ACs[1]
end

"""
Compute the up environment tensor for MPS `FL` and `FR`, by finding the up fixed point
    of `FL - FR` contracted along the physical dimension.
````
┌──C──┐                      a ─── b
│     │          ┌──C──┐     │     │
FL─── FR  =  λC  │     │     ├─ c ─┤
│     │                      │     │
                             d ─── e
````
"""
function Cenv(C, FL, FR;kwargs...)
    λs, Cs, _ = eigsolve(C -> ein"(acd,ab),bce -> de"(FL,C,FR), C, 1, :LM; ishermitian = false, kwargs...)
    if length(λs) > 1 && norm(abs(λs[1]) - abs(λs[2])) < 1e-12
        @show λs
        if real(λs[1]) > 0
            return real(λs[1]), real(Cs[1])
        else
            return real(λs[2]), real(Cs[2])
        end
    end
    return λs[1], Cs[1]
end

"""
    AL, AR, errL, errR = ACCtoALAR(AC, C) 

QR factorization to get `AL` and `AR` from `AC` and `C`

````
──AL──C──  =  ──AC──  = ──C──AR──
  │             │            │   
````
"""
function ACCtoALAR(AC, C)
    D, d, = size(AC)

    QAC, RAC = qrpos(reshape(AC,(D*d, D)))
    QC, RC = qrpos(C)
    AL = reshape(QAC*QC', (D, d, D))
    errL = norm(RAC-RC)
    
    LAC, QAC = lqpos(reshape(AC,(D, d*D)))
    LC, QC = lqpos(C)
    AR = reshape(QC'*QAC, (D, d, D))
    errR = norm(LAC-LC)

    return AL, AR, errL, errR
end

"""
    err = error(AL,C,FL,M,FR)

Compute the error through all environment `AL,C,FL,M,FR`

````
        ┌── AC──┐         
        │   │   │           ┌── AC──┐ 
MAC1 =  FL─ M ──FR  =  λAC  │   │   │ 
        │   │   │         

        ┌── AC──┐         
        │   │   │           ┌──C──┐ 
MAC2 =  FL─ M ──FR  =  λAC  │     │ 
        │   │   │         
        ┕── AL─     
        
── MAC1 ──    ≈    ── AL ── MAC2 ── 
    │                 │
````
"""
function error(AL,C,AR,FL,M,FR)
    AC = ein"abc,cd -> abd"(AL,C)
    MAC = ein"((adf,abc),dgeb),ceh -> fgh"(FL,AC,M,FR)
    # MC = ein"(αaγ,γη),ηaβ -> αβ"(FL,C,FR)
    # MAL, MAR, _, _ = ACCtoALAR(MAC, MC)
    # _, FL_n = norm_FL(MAL, AL)
    # _, FR_n = norm_FR(MAR, AR)
    # println("overlap = $(ein"((ae,adb),bc),((edf,fg),cg) ->"(FL_n,MAL,MC,AL,C,FR_n)[]/ein"ac,ab,bd,cd ->"(FL_n,MC,FR_n,C)[])") 
    MAC -= ein"asd,(cpd,cpb) -> asb"(AL,conj(AL),MAC)
    norm(MAC)
end