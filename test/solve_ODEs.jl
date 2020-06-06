### Checks the solutions of specific problems ###

# Exponential decay, should be identical to the (known) analytical solution.
exponential_decay = @reaction_network begin
    d, X → ∅
end d

for factor in [1e-2, 1e-1, 1e0, 1e1, 1e2, 1e3]
    u0 = factor*rand(length(exponential_decay.states))
    p = factor*rand(length(exponential_decay.ps))
    prob = ODEProblem(exponential_decay,u0,(0.,100/factor),p)
    sol = solve(prob,Rosenbrock23(),saveat=range(0.,100/factor,length=101))
    analytic_sol = map(t -> u0[1]*exp(-p[1]*t),range(0.,100/factor,length=101))
    all(abs(first.(sol.u) .- analytic_sol) .< 1e-8)
end

# Networks with know equilibrium
known_equilibrium = @reaction_network begin
    (k1,k2), X1 ↔ X2
    (k3,k4), X3+ X4 ↔ X5
    (k5,k6), 2X6 ↔ 3X7
    (k7,k8), ∅ ↔ X8
end k1 k2 k3 k4 k5 k6 k7 k8

for factor in [1e-1, 1e0, 1e1, 1e2, 1e3]
    u0 = factor*rand(length(known_equilibrium.states))
    p = 0.01 .+ factor*rand(length(known_equilibrium.ps))
    prob = ODEProblem(known_equilibrium,u0,(0.,1000000.),p)
    sol = solve(prob,Rosenbrock23())
    @test abs.(sol.u[end][1]/sol.u[end][2] - p[2]/p[1]) < 100*eps()
    @test abs.(sol.u[end][3]*sol.u[end][4]/sol.u[end][5] - p[4]/p[3]) < 100*eps()
    @test abs.((sol.u[end][6]^2/factorial(2))/(sol.u[end][7]^3/factorial(3))- p[6]/p[5]) < 1e-10
    @test abs.(sol.u[end][8]  - p[7]/p[8]) < 100*eps()
end


### Compares to the manually calcualted function ###
identical_networks_1 = Vector{Pair}()

function real_functions_1(du,u,p,t)
    X1,X2,X2 = u
    p1,p2,p3,k1,k2,k3,k4,d1,d2,d3 = p
    du[1] = p1 + k1*X2 - k2*X1*X3^2/factorial(2) - k3*X1 + k4*X3 - d1*X1
    du[2] = p2 - k1*X2 + k2*X1*X3^2/factorial(2) - d2*X2
    du[3] = p3 + 2*k1*X2 - 2*k2*X1*X3^2/factorial(2) + k3*X1 - k4*X3 - d3*X1
end
push!(identical_networks_1, reaction_networks_standard[1] => real_functions_1)

function real_functions_2(du,u,p,t)
    X1,X2 = u
    v1,K1,v2,K2,d = p
    du[1] = v1*K1/(K1+X2) - d*X1
    du[2] = v2*K2/(K2+X1) - d*X2
end
push!(identical_networks_1, reaction_networks_standard[2] => real_functions_2)

function real_functions_3(du,u,p,t)
X1,X2,X3 = u
    v1,v2,v3,K1,K2,K3,n1,n2,n3,d1,d2,d3 = p
    du[1] = v1*K1^n1/(K1^n1+X3^n1) - d1*X1
    du[1] = v2*K2^n2/(K2^n2+X1^n2) - d2*X3
    du[1] = v3*K3^n3/(K3^n3+X2^n3) - d3*X3
end
push!(identical_networks_1, reaction_networks_hill[2] => real_functions_3)

function real_functions_4(du,u,p,t)
X1,X2,X3 = u
    k1,k2,k3,k4,k5,k6 = p
    du[1] = -k1*X1 + k2*X2 + k5*X3 - k6*X1
    du[2] = -k3*X2 + k4*X3 + k1*X1 - k2*X2
    du[3] = -k5*X3 + k6*X1 + k3*X2 - k4*X3
end
push!(identical_networks_1, reaction_networks_constraint[1] => real_functions_4)

function real_functions_5(du,u,p,t)
    k1,k2,k3,k4 = p
    X,Y,Z = u
    du[1] = k1 - k2*log(12+X)*X
    du[2] = k2*log(12+X)*X - k3*log(3+Y)*Y
    du[3] = k3*log(3+Y)*Y - log(5,6+k4)*Z
end
push!(identical_networks_1, reaction_networks_weird[2] => real_functions_5)

for networks in identical_networks_1
    for factor in [1e-2, 1e-1, 1e0, 1e1, 1e2, 1e3]
        u0 = factor*rand(length(networks[1].states))
        p = factor*rand(length(networks[1].ps))
        prob1 = ODEProblem(networks[1],u0,(0.,100.),p)
        sol1 = solve(prob1,Rosenbrock23(),saveat=1.)
        prob2 = ODEProblem(networks[2],u0,(0.,100.),p)
        sol2 = solve(prob1,Rosenbrock23(),saveat=1.)
        @test all(abs.(hcat((sol1.u .- sol2.u)...)) .< 100*eps())
    end
end


### Tries solving a large number of problem, ensuring there are no errors. ###
for reaction_network in reaction_networks_all
    for factor in [1e-2, 1e-1, 1e0, 1e1]
        u0 = factor*rand(length(reaction_network.states))
        p = factor*rand(length(reaction_network.ps))
        prob = ODEProblem(reaction_network,u0,(0.,1.),p)
        solve(prob,Rosenbrock23())
    end
end
