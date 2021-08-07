using BenchmarkTools 
using OMEinsum
using OMEinsum: get_size_dict, optimize_greedy,  MinSpaceDiff
using Test

@testset "einsum optimize with $atype" for atype in [CuArray]
    D = 4
    χ = 20
    
    C = atype(rand(χ,χ))
    ap = atype(rand(D^2,D^2,D^2,D^2,2,2))
    FL4 = atype(rand(χ,D^2,D^2,χ))
    # 王 = atype(rand(χ,D^2,χ,χ,D^2,χ))
    m = atype(rand(D,D,D,D,2))
    M = ein"abcdi,efghi -> aebfcgdh"(m,m)
    M = reshape(M,(D^2,D^2,D^2,D^2))
    f = atype(rand(χ,D,D,χ)) 
    F = reshape(f, (χ,D^2,χ))

    function getoc(ein::EinCode{ixs, iy}, xs) where {ixs, iy}
        @time begin
            sd = get_size_dict(ixs, xs);
            oc = optimize_greedy(ein, sd; method = MinSpaceDiff())
        end
        display(oc)
        return oc
    end

    # ein = ein"abc,cde,afi,bfgj,dghl,ijk,klm -> ehm"
    # xs = (AL,AL,FL,M,M,AL,AL)
    # oc = getoc(ein, xs)
    # @btime $oc($AL,$AL,$FL,$M,$M,$AL,$AL)
    # function foo(FL,AL,M)
    #     FL = ein"((afi,abc),bfgj),ijk -> cgk"(FL,AL,M,AL)
    #     ein"((afi,abc),bfgj),ijk -> cgk"(FL,AL,M,AL)
    # end
    # @btime $foo($FL,$AL,$M)

    # ein = ein"asd,cpd,cpb -> asb"
    # xs = (AL,AL,AL)
    # oc = getoc(ein, xs)
    # @btime $oc($AL,$AL,$AL)
    # @btime ein"(asd,cpd),cpb -> asb"($AL,$AL,$AL)

    # ein = ein"dcba,def,ckge,bjhk,aji -> fghi"
    # xs = (FL4,AL,M,M,AL)
    # oc = getoc(ein, xs)

    # ein = ein"αcβ,βsη,cpds,ηdγ,αpγ -> "
    # xs = (FL,AL,M,FR,AL)
    # oc = getoc(ein, xs)
    
    # ein = ein"αcβ,βη,ηcγ,αγ -> "
    # xs = (AL,C,AL,C)
    # oc = getoc(ein, xs)

    # ein = ein"γcη,ηpβ,γsα,βaα -> csap"
    # xs = (AL,AL,AL,AL)
    # oc = getoc(ein, xs)

    ein = ein"adf,abc,dgeb,ceh -> fgh"
    xs = (F, F, M, F)
    oc1 = getoc(ein, xs)
    @btime $oc1($F, $F, $M, $F)

    ein = ein"abcd,aegi,ejfbm, gkhcm, dfhl -> ijkl"
    xs = (f, f, m, m, f)
    oc2 = getoc(ein, xs)
    @btime $oc2($f, $f, $m, $m, $f)

    @test oc1(F, F, M, F) ≈ reshape(oc2(f, f, m, m, f), (χ, D^2, χ))
end