@testitem "InitDescriptor" begin
    using RxInfer
    import RxInfer: InitDescriptor, InitMessage, InitMarginal
    import GraphPPL: IndexedVariable

    @test @inferred(InitDescriptor(InitMessage(), GraphPPL.IndexedVariable(:x, nothing))) == InitDescriptor{InitMessage}(InitMessage(), IndexedVariable(:x, nothing))
    @test @inferred(InitDescriptor(InitMarginal(), GraphPPL.IndexedVariable(:x, nothing))) == InitDescriptor{InitMarginal}(InitMarginal(), IndexedVariable(:x, nothing))
end

@testitem "InitObject" begin
    using RxInfer
    import RxInfer: InitObject, InitDescriptor, InitMessage, InitMarginal

    @test @inferred(InitObject(InitDescriptor(InitMessage(), GraphPPL.IndexedVariable(:x, nothing)), Normal(0, 10))) ===
        InitObject(InitDescriptor(InitMessage(), GraphPPL.IndexedVariable(:x, nothing)), Normal(0, 10))
    @test @inferred(InitObject(InitDescriptor(InitMarginal(), GraphPPL.IndexedVariable(:x, nothing)), Normal(0, 10))) ===
        InitObject(InitDescriptor(InitMarginal(), GraphPPL.IndexedVariable(:x, nothing)), Normal(0, 10))

    @test occursin(r"μ\(x\) = ", repr(InitObject(InitDescriptor(InitMessage(), GraphPPL.IndexedVariable(:x, nothing)), Normal(0, 10))))
    @test occursin(r"q\(x\) = ", repr(InitObject(InitDescriptor(InitMarginal(), GraphPPL.IndexedVariable(:x, nothing)), Normal(0, 10))))
end

@testitem "SpecificSubModelInit" begin
    using RxInfer
    using GraphPPL
    import RxInfer: SpecificSubModelInit, InitSpecification, InitDescriptor, InitMarginal, InitObject, GeneralSubModelInit

    @model function dummymodel()
        x ~ Normal(0, 1)
        y ~ Normal(x, 1)
    end

    @test SpecificSubModelInit(GraphPPL.FactorID(dummymodel, 1), InitSpecification()) isa SpecificSubModelInit
    push!(SpecificSubModelInit(GraphPPL.FactorID(dummymodel, 1)), InitObject(InitDescriptor(InitMarginal(), GraphPPL.IndexedVariable(:x, nothing)), Normal(0, 10)))
    push!(SpecificSubModelInit(GraphPPL.FactorID(dummymodel, 1), InitSpecification()), SpecificSubModelInit(GraphPPL.FactorID(sum, 1), InitSpecification()))
    push!(SpecificSubModelInit(GraphPPL.FactorID(dummymodel, 1), InitSpecification()), GeneralSubModelInit(dummymodel, InitSpecification()))
end

@testitem "GeneralSubModelInit" begin
    using RxInfer
    using GraphPPL
    import RxInfer: SpecificSubModelInit, InitSpecification, InitDescriptor, InitMarginal, InitObject, GeneralSubModelInit

    @model function dummymodel()
        x ~ Normal(0, 1)
        y ~ Normal(x, 1)
    end

    @test GeneralSubModelInit(dummymodel, InitSpecification()) isa GeneralSubModelInit
    push!(GeneralSubModelInit(dummymodel, InitSpecification()), InitObject(InitDescriptor(InitMarginal(), GraphPPL.IndexedVariable(:x, nothing)), Normal(0, 10)))
    push!(GeneralSubModelInit(dummymodel, InitSpecification()), SpecificSubModelInit(GraphPPL.FactorID(sum, 1), InitSpecification()))
    init = InitSpecification()
    push!(init, GeneralSubModelInit(dummymodel, InitSpecification()))
end

@testitem "filter general and specific submodel init" begin
    using RxInfer
    using GraphPPL
    import RxInfer: SpecificSubModelInit, InitSpecification, InitDescriptor, InitMarginal, InitObject, GeneralSubModelInit, getgeneralsubmodelinit, getspecificsubmodelinit
    import GraphPPL: FactorID, hasextra

    init = InitSpecification()
    push!(init, GeneralSubModelInit(sin, InitSpecification()))
    @test length(getgeneralsubmodelinit(init)) === 1
    @test length(getspecificsubmodelinit(init)) === 0

    push!(init, SpecificSubModelInit(FactorID(sum, 1), InitSpecification()))

    @test length(getgeneralsubmodelinit(init)) === 1
    @test length(getspecificsubmodelinit(init)) === 1

    @test getspecificsubmodelinit(init, FactorID(sum, 1)).tag == FactorID(sum, 1)
    @test getspecificsubmodelinit(init, FactorID(sum, 5)) === nothing

    @test getgeneralsubmodelinit(init, sin).fform == sin
end

@testitem "apply!(::Model, ::Context, ::InitObject)" begin
    using RxInfer
    using GraphPPL
    import RxInfer:
        SpecificSubModelInit,
        InitSpecification,
        InitDescriptor,
        InitMessage,
        InitMarginal,
        InitObject,
        GeneralSubModelInit,
        getgeneralsubmodelinit,
        getspecificsubmodelinit,
        apply_init!,
        InitMsgExtraKey,
        InitMarExtraKey
    import GraphPPL: create_model, getcontext, getextra, hasextra

    @model function gcv(κ, ω, z, x, y)
        log_σ := κ * z + ω
        y ~ Normal(x, exp(log_σ))
    end

    @model function gcv_collection()
        κ ~ Normal(0, 1)
        ω ~ Normal(0, 1)
        z ~ Normal(0, 1)
        for i in 1:10
            x[i] ~ Normal(0, 1)
            y[i] ~ gcv(κ = κ, ω = ω, z = z, x = x[i])
        end
    end

    # Test apply init marginal for top level variable
    model = create_model(gcv_collection())
    context = getcontext(model)
    init = InitSpecification([InitObject(InitDescriptor(InitMarginal(), GraphPPL.IndexedVariable(:κ, nothing)), Normal(0, 1))], [])
    apply_init!(model, context, init)
    node = context[:κ]
    @test !hasextra(model[node], InitMsgExtraKey)
    @test getextra(model[node], InitMarExtraKey) == Normal(0, 1)
    node = context[:ω]
    @test !hasextra(model[node], InitMsgExtraKey)
    @test !hasextra(model[node], InitMarExtraKey)

    # Test apply init marginal for top level variable
    model = create_model(gcv_collection())
    context = getcontext(model)
    init = InitSpecification([InitObject(InitDescriptor(InitMessage(), GraphPPL.IndexedVariable(:κ, nothing)), Normal(0, 1))], [])
    apply_init!(model, context, init)
    node = context[:κ]
    @test getextra(model[node], InitMsgExtraKey) == Normal(0, 1)
    @test !hasextra(model[node], InitMarExtraKey)
    node = context[:ω]
    @test !hasextra(model[node], InitMsgExtraKey)
    @test !hasextra(model[node], InitMarExtraKey)

    # Test apply init marginal for a vector of variables
    model = create_model(gcv_collection())
    context = getcontext(model)
    init = InitSpecification([InitObject(InitDescriptor(InitMessage(), GraphPPL.IndexedVariable(:x, nothing)), Normal(0, 1))], [])
    apply_init!(model, context, init)
    node_c = context[:x]
    for node in node_c
        @test getextra(model[node], InitMsgExtraKey) == Normal(0, 1)
        @test !hasextra(model[node], InitMarExtraKey)
    end
    node = context[:ω]
    @test !hasextra(model[node], InitMsgExtraKey)
    @test !hasextra(model[node], InitMarExtraKey)

    # Test apply init message for a vector of variables
    model = create_model(gcv_collection())
    context = getcontext(model)
    init = InitSpecification([InitObject(InitDescriptor(InitMarginal(), GraphPPL.IndexedVariable(:x, nothing)), Normal(0, 1))], [])
    apply_init!(model, context, init)
    node_c = context[:x]
    for node in node_c
        @test !hasextra(model[node], InitMsgExtraKey)
        @test getextra(model[node], InitMarExtraKey) == Normal(0, 1)
    end
    node = context[:ω]
    @test !hasextra(model[node], InitMsgExtraKey)
    @test !hasextra(model[node], InitMarExtraKey)

    # Test apply init message for an element of a vector
    model = create_model(gcv_collection())
    context = getcontext(model)
    init = InitSpecification([InitObject(InitDescriptor(InitMarginal(), GraphPPL.IndexedVariable(:x, 1)), Normal(0, 1))], [])
    apply_init!(model, context, init)
    node = context[:x][1]
    @test !hasextra(model[node], InitMsgExtraKey)
    @test getextra(model[node], InitMarExtraKey) == Normal(0, 1)
    for i in 2:10
        lnode = context[:x][i]
        @test !hasextra(model[lnode], InitMsgExtraKey)
        @test !hasextra(model[lnode], InitMarExtraKey)
    end

    # Test apply init message for an element of a vector
    model = create_model(gcv_collection())
    context = getcontext(model)
    init = InitSpecification([InitObject(InitDescriptor(InitMessage(), GraphPPL.IndexedVariable(:x, 1)), Normal(0, 1))], [])
    apply_init!(model, context, init)
    node = context[:x][1]
    @test getextra(model[node], InitMsgExtraKey) == Normal(0, 1)
    @test !hasextra(model[node], InitMarExtraKey)
    for i in 2:10
        lnode = context[:x][i]
        @test !hasextra(model[lnode], InitMsgExtraKey)
        @test !hasextra(model[lnode], InitMarExtraKey)
    end

    # Test apply init message for a specific submodel
    model = create_model(gcv_collection())
    context = getcontext(model)
    init = InitSpecification(
        [],
        [
            SpecificSubModelInit(
                GraphPPL.FactorID(gcv, 1), InitSpecification([InitObject(InitDescriptor(InitMarginal(), GraphPPL.IndexedVariable(:log_σ, nothing)), Normal(0, 1))], [])
            )
        ]
    )
    apply_init!(model, context, init)
    node = context[gcv, 1][:log_σ]
    @test !hasextra(model[node], InitMsgExtraKey)
    @test getextra(model[node], InitMarExtraKey) == Normal(0, 1)
    for i in 2:10
        lnode = context[gcv, i][:log_σ]
        @test !hasextra(model[lnode], InitMsgExtraKey)
        @test !hasextra(model[lnode], InitMarExtraKey)
    end

    # Test apply init marginal for a specific submodel
    model = create_model(gcv_collection())
    context = getcontext(model)
    init = InitSpecification(
        [],
        [
            SpecificSubModelInit(
                GraphPPL.FactorID(gcv, 1), InitSpecification([InitObject(InitDescriptor(InitMessage(), GraphPPL.IndexedVariable(:log_σ, nothing)), Normal(0, 1))], [])
            )
        ]
    )
    apply_init!(model, context, init)
    node = context[gcv, 1][:log_σ]
    @test getextra(model[node], InitMsgExtraKey) == Normal(0, 1)
    @test !hasextra(model[node], InitMarExtraKey)
    for i in 2:10
        lnode = context[gcv, i][:log_σ]
        @test !hasextra(model[lnode], InitMsgExtraKey)
        @test !hasextra(model[lnode], InitMarExtraKey)
    end

    # Test apply init marginal for a general submodel
    model = create_model(gcv_collection())
    context = getcontext(model)
    init = InitSpecification(
        [], [GeneralSubModelInit(gcv, InitSpecification([InitObject(InitDescriptor(InitMarginal(), GraphPPL.IndexedVariable(:log_σ, nothing)), Normal(0, 1))], []))]
    )
    apply_init!(model, context, init)
    for i in 1:10
        lnode = context[gcv, i][:log_σ]
        @test !hasextra(model[lnode], InitMsgExtraKey)
        @test getextra(model[lnode], InitMarExtraKey) == Normal(0, 1)
    end

    # Test apply init message for a general submodel
    model = create_model(gcv_collection())
    context = getcontext(model)
    init = InitSpecification(
        [], [GeneralSubModelInit(gcv, InitSpecification([InitObject(InitDescriptor(InitMessage(), GraphPPL.IndexedVariable(:log_σ, nothing)), Normal(0, 1))], []))]
    )
    apply_init!(model, context, init)
    for i in 1:10
        lnode = context[gcv, i][:log_σ]
        @test getextra(model[lnode], InitMsgExtraKey) == Normal(0, 1)
        @test !hasextra(model[lnode], InitMarExtraKey)
    end
end

@testitem "check_for_returns" begin
    using RxInfer
    using GraphPPL
    import RxInfer: check_for_returns_init

    include("../utiltests.jl")

    # Test 1: check_for_returns_init with one statement
    input = quote
        q(x) = Normal(0, 1)
        μ(z) = Normal(0, 1)
    end
    @test_expression_generating GraphPPL.apply_pipeline(input, check_for_returns_init) input

    # Test 2: check_for_returns_init with a return statement
    input = quote
        q(x) = Normal(0, 1)
        μ(z) = Normal(0, 1)
        return nothing
    end
    @test_throws ErrorException("The init macro does not support return statements.") GraphPPL.apply_pipeline(input, check_for_returns_init)
end

@testitem "add_init_constructor" begin
    import RxInfer: add_init_construction
    import GraphPPL: apply_pipeline

    include("../utiltests.jl")

    # Test 1: add_constraints_construction to regular constraint specification
    input = quote
        q(x) = Normal(0, 1)
        μ(z) = Normal(0, 1)
    end
    output = quote
        let __init__ = RxInfer.InitSpecification()
            $input
            __init__
        end
    end
    @test_expression_generating add_init_construction(input) output

    # Test 2: add_constraints_construction to constraint specification with nested model specification
    input = input = quote
        q(x) = Normal(0, 1)
        μ(z) = Normal(0, 1)
        for init in submodel
            q(x) = Normal(0, 1)
            μ(z) = Normal(0, 1)
        end
    end
    output = quote
        let __init__ = RxInfer.InitSpecification()
            $input
            __init__
        end
    end
    @test_expression_generating add_init_construction(input) output

    # Test 3: add_constraints_construction to constraint specification with function specification
    input = quote
        function someinit()
            q(x) = Normal(0, 1)
            μ(z) = Normal(0, 1)
        end
    end
    output = quote
        function someinit(;)
            __init__ = RxInfer.InitSpecification()
            q(x) = Normal(0, 1)
            μ(z) = Normal(0, 1)
            return __init__
        end
    end
    @test_expression_generating add_init_construction(input) output

    # Test 4: add_constraints_construction to constraint specification with function specification and arguments
    input = quote
        function someinit(x, y)
            q(x) = Normal(0, 1)
            μ(z) = Normal(0, 1)
        end
    end
    output = quote
        function someinit(x, y;)
            __init__ = RxInfer.InitSpecification()
            q(x) = Normal(0, 1)
            μ(z) = Normal(0, 1)
            return __init__
        end
    end
    @test_expression_generating add_init_construction(input) output

    # Test 5: add_constraints_construction to constraint specification with function specification and arguments and keyword arguments
    input = quote
        function someinit(x, y; z)
            q(x) = Normal(0, 1)
            μ(z) = Normal(0, 1)
        end
    end
    output = quote
        function someinit(x, y; z)
            __init__ = RxInfer.InitSpecification()
            q(x) = Normal(0, 1)
            μ(z) = Normal(0, 1)
            return __init__
        end
    end
    @test_expression_generating add_init_construction(input) output

    # Test 6: add_constraints_construction to constraint specification with function specification and only keyword arguments
    input = quote
        function someinit(; z)
            q(x) = Normal(0, 1)
            μ(z) = Normal(0, 1)
        end
    end
    output = quote
        function someinit(; z)
            __init__ = RxInfer.InitSpecification()
            q(x) = Normal(0, 1)
            μ(z) = Normal(0, 1)
            return __init__
        end
    end
    @test_expression_generating add_init_construction(input) output
end

@testitem "create_submodel_init" begin
    import RxInfer: create_submodel_init
    import GraphPPL: apply_pipeline

    include("../utiltests.jl")

    # Test 1: create_submodel_init with one nested layer
    input = quote
        __init__ = RxInfer.InitSpecification()
        q(x) = Normal(0, 1)
        μ(z) = Normal(0, 1)
        for init in submodel
            q(x) = Normal(0, 1)
            μ(z) = Normal(0, 1)
        end
        q(x) = Normal(0, 1)
        μ(z) = Normal(0, 1)
        __init__
    end
    output = quote
        __init__ = RxInfer.InitSpecification()
        q(x) = Normal(0, 1)
        μ(z) = Normal(0, 1)
        let __outer_init__ = __init__
            let __init__ = RxInfer.GeneralSubModelInit(submodel)
                q(x) = Normal(0, 1)
                μ(z) = Normal(0, 1)
                push!(__outer_init__, __init__)
            end
        end
        q(x) = Normal(0, 1)
        μ(z) = Normal(0, 1)
        __init__
    end
    @test_expression_generating apply_pipeline(input, create_submodel_init) output

    # Test 2: create_submodel_init with two nested layers
    input = quote
        __init__ = RxInfer.InitSpecification()
        q(x) = Normal(0, 1)
        μ(z) = Normal(0, 1)
        for init in submodel
            q(x) = Normal(0, 1)
            μ(z) = Normal(0, 1)
            for init in (subsubmodel, 1)
                q(x) = Normal(0, 1)
                μ(z) = Normal(0, 1)
            end
        end
        q(x) = Normal(0, 1)
        μ(z) = Normal(0, 1)
        __init__
    end
    output = quote
        __init__ = RxInfer.InitSpecification()
        q(x) = Normal(0, 1)
        μ(z) = Normal(0, 1)
        let __outer_init__ = __init__
            let __init__ = RxInfer.GeneralSubModelInit(submodel)
                q(x) = Normal(0, 1)
                μ(z) = Normal(0, 1)
                let __outer_init__ = __init__
                    let __init__ = RxInfer.SpecificSubModelInit(RxInfer.GraphPPL.FactorID(subsubmodel, 1))
                        q(x) = Normal(0, 1)
                        μ(z) = Normal(0, 1)
                        push!(__outer_init__, __init__)
                    end
                end
                push!(__outer_init__, __init__)
            end
        end
        q(x) = Normal(0, 1)
        μ(z) = Normal(0, 1)
        __init__
    end
    @test_expression_generating apply_pipeline(input, create_submodel_init) output
end

@testitem "convert_init_variables" begin
    import RxInfer: convert_init_variables
    import GraphPPL: apply_pipeline

    include("../utiltests.jl")

    # Test 1: convert_init_variables with non-indexed variables in Factor init call
    input = quote
        q(x) = Normal(0, 1)
        μ(z) = Normal(0, 1)
    end
    output = quote
        q(GraphPPL.IndexedVariable(:x, nothing)) = Normal(0, 1)
        μ(GraphPPL.IndexedVariable(:z, nothing)) = Normal(0, 1)
    end
    @test_expression_generating apply_pipeline(input, convert_init_variables) output

    # Test 2: convert_init_variables with indexed variables in Factor init call
    input = quote
        q(x[1]) = Normal(0, 1)
    end
    output = quote
        q(GraphPPL.IndexedVariable(:x, 1)) = Normal(0, 1)
    end
    @test_expression_generating apply_pipeline(input, convert_init_variables) output
end

@testitem "convert_init_object" begin
    import RxInfer: convert_init_object
    import GraphPPL: apply_pipeline

    include("../utiltests.jl")

    # Test 1: convert_init_object with marginal and indexed statement
    input = quote
        q(GraphPPL.IndexedVariable(:x, 1)) = Normal(0, 1)
    end
    output = quote
        push!(__init__, RxInfer.InitObject(RxInfer.InitDescriptor(RxInfer.InitMarginal(), GraphPPL.IndexedVariable(:x, 1)), Normal(0, 1)))
    end
    @test_expression_generating apply_pipeline(input, convert_init_object) output

    # Test 2: convert_init_object with marginal and non-indexed statement
    input = quote
        q(GraphPPL.IndexedVariable(:x, nothing)) = Normal(0, 1)
    end
    output = quote
        push!(__init__, RxInfer.InitObject(RxInfer.InitDescriptor(RxInfer.InitMarginal(), GraphPPL.IndexedVariable(:x, nothing)), Normal(0, 1)))
    end
    @test_expression_generating apply_pipeline(input, convert_init_object) output

    # Test 3: convert_init_object with message and indexed statement
    input = quote
        μ(GraphPPL.IndexedVariable(:x, 1)) = Normal(0, 1)
    end
    output = quote
        push!(__init__, RxInfer.InitObject(RxInfer.InitDescriptor(RxInfer.InitMessage(), GraphPPL.IndexedVariable(:x, 1)), Normal(0, 1)))
    end
    @test_expression_generating apply_pipeline(input, convert_init_object) output

    # Test 4: convert_init_object with message and non-indexed statement
    input = quote
        μ(GraphPPL.IndexedVariable(:x, nothing)) = Normal(0, 1)
    end
    output = quote
        push!(__init__, RxInfer.InitObject(RxInfer.InitDescriptor(RxInfer.InitMessage(), GraphPPL.IndexedVariable(:x, nothing)), Normal(0, 1)))
    end
    @test_expression_generating apply_pipeline(input, convert_init_object) output
end

@testitem "init_macro_interior" begin
    import RxInfer: init_macro_interior

    include("../utiltests.jl")

    # Test 1: init_macro_interor with one statement
    input = quote
        q(x) = Normal(0, 1)
    end
    output = quote
        let __init__ = RxInfer.InitSpecification()
            push!(__init__, RxInfer.InitObject(RxInfer.InitDescriptor(RxInfer.InitMarginal(), GraphPPL.IndexedVariable(:x, nothing)), Normal(0, 1)))
            __init__
        end
    end
    @test_expression_generating init_macro_interior(input) output

    # Test 2: init_macro_interor with multiple statements
    input = quote
        q(x) = Normal(0, 1)
        μ(z) = Normal(0, 1)
    end
    output = quote
        let __init__ = RxInfer.InitSpecification()
            push!(__init__, RxInfer.InitObject(RxInfer.InitDescriptor(RxInfer.InitMarginal(), GraphPPL.IndexedVariable(:x, nothing)), Normal(0, 1)))
            push!(__init__, RxInfer.InitObject(RxInfer.InitDescriptor(RxInfer.InitMessage(), GraphPPL.IndexedVariable(:z, nothing)), Normal(0, 1)))
            __init__
        end
    end
    @test_expression_generating init_macro_interior(input) output

    # Test 3: init_macro_interor with multiple statements and a submodel definition
    input = quote
        q(x) = Normal(0, 1)
        μ(z) = Normal(0, 1)
        for init in submodel
            q(x) = Normal(0, 1)
            μ(z) = Normal(0, 1)
        end
    end
    output = quote
        let __init__ = RxInfer.InitSpecification()
            push!(__init__, RxInfer.InitObject(RxInfer.InitDescriptor(RxInfer.InitMarginal(), GraphPPL.IndexedVariable(:x, nothing)), Normal(0, 1)))
            push!(__init__, RxInfer.InitObject(RxInfer.InitDescriptor(RxInfer.InitMessage(), GraphPPL.IndexedVariable(:z, nothing)), Normal(0, 1)))
            let __outer_init__ = __init__
                let __init__ = RxInfer.GeneralSubModelInit(submodel)
                    push!(__init__, RxInfer.InitObject(RxInfer.InitDescriptor(RxInfer.InitMarginal(), GraphPPL.IndexedVariable(:x, nothing)), Normal(0, 1)))
                    push!(__init__, RxInfer.InitObject(RxInfer.InitDescriptor(RxInfer.InitMessage(), GraphPPL.IndexedVariable(:z, nothing)), Normal(0, 1)))
                    push!(__outer_init__, __init__)
                end
            end
            __init__
        end
    end
    @test_expression_generating init_macro_interior(input) output
end
