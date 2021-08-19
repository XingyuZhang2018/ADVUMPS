using ADVUMPS
using ADVUMPS: energy, num_grad, diaglocal, optcont
using CUDA
using LinearAlgebra: svd, norm
using LineSearches, Optim
using OMEinsum
using Random
using Zygote

CUDA.allowscalar(false)
atype = CuArray
Random.seed!(100)
model = Heisenberg(1.0,1.0,1.0)
ipeps, key = init_ipeps(model;atype = atype, D=6, χ=30, tol=1e-10, maxiter=10)
res = optimiseipeps(ipeps, key; f_tol = 1e-6, opiter = 100, verbose = true)
e = minimum(res)