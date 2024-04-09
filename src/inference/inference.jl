export KeepEach, KeepLast
export infer, inference, rxinference
export InferenceResult
export RxInferenceEngine, RxInferenceEvent

import DataStructures: CircularBuffer
import GraphPPL: ModelGenerator, create_model

import ReactiveMP: israndom, isdata, isconst
import ReactiveMP: CountingReal

import ProgressMeter

obtain_prediction(variable::Any) = getprediction(variable)
obtain_prediction(variables::AbstractArray) = getpredictions(variables)

obtain_marginal(variable::Any, strategy = SkipInitial()) = getmarginal(variable, strategy)
obtain_marginal(variables::AbstractArray, strategy = SkipInitial()) = getmarginals(variables, strategy)

assign_marginal!(variable::Any, marginal) = setmarginal!(variable, marginal)
assign_marginal!(variables::AbstractArray, marginals) = setmarginals!(variables, marginals)

assign_message!(variable::Any, message) = setmessage!(variable, message)
assign_message!(variables::AbstractArray, messages) = setmessages!(variables, messages)

struct KeepEach end
struct KeepLast end

make_actor(::Any, ::KeepEach) = keep(Marginal)
# make_actor(::Array{<:AbstractVariable, N}, ::KeepEach) where {N} = keep(Array{Marginal, N})
make_actor(x::AbstractArray, ::KeepEach) = keep(typeof(similar(x, Marginal)))

make_actor(::Any, ::KeepEach, capacity::Integer) = circularkeep(Marginal, capacity)
make_actor(x::AbstractArray, ::KeepEach, capacity::Integer) = circularkeep(typeof(similar(x, Marginal)), capacity)

make_actor(::Any, ::KeepLast) = storage(Marginal)
make_actor(x::AbstractArray, ::KeepLast) = buffer(Marginal, size(x))

make_actor(::Any, ::KeepLast, capacity::Integer) = storage(Marginal)
make_actor(x::AbstractArray, ::KeepLast, capacity::Integer) = buffer(Marginal, size(x))

## Inference ensure update

import Rocket: Actor, on_next!, on_error!, on_complete!

# We can use `MarginalHasBeenUpdated` both as an actor in within the `ensure_update` operator
mutable struct MarginalHasBeenUpdated <: Actor{Any}
    updated::Bool
end

__unset_updated!(updated::MarginalHasBeenUpdated) = updated.updated = false
__set_updated!(updated::MarginalHasBeenUpdated)   = updated.updated = true

Rocket.on_next!(updated::MarginalHasBeenUpdated, anything) = __set_updated!(updated)
Rocket.on_error!(updated::MarginalHasBeenUpdated, err)     = begin end
Rocket.on_complete!(updated::MarginalHasBeenUpdated)       = begin end

# This creates a `tap` operator that will set the `updated` flag to true. 
# Later on we check flags and `unset!` them after the `update!` procedure
ensure_update(model::ProbabilisticModel, callback, variable_name::Symbol, updated::MarginalHasBeenUpdated) =
    tap() do update
        __set_updated!(updated)
        callback(model, variable_name, update)
    end

ensure_update(model::ProbabilisticModel, ::Nothing, variable_name::Symbol, updated::MarginalHasBeenUpdated) =
    tap() do _
        __set_updated!(updated) # If `callback` is nothing we simply set updated flag
    end

function __check_and_unset_updated!(updates)
    if all((v) -> v.updated, values(updates))
        foreach(__unset_updated!, values(updates))
    else
        not_updated = filter((pair) -> !last(pair).updated, updates)
        names = join(keys(not_updated), ", ")
        error("""
              Variables [ $(names) ] have not been updated after an update event. 
              Therefore, make sure to initialize all required marginals and messages. See `initmarginals` and `initmessages` keyword arguments for the inference function. 
              See the function documentation for detailed information regarding the initialization.
              """)
    end
end

## Extra error handling

function __inference_process_error(error)
    # By default, rethrow the error
    return __inference_process_error(error, true)
end

function __inference_process_error(error, rethrow)
    if rethrow
        Base.rethrow(error)
    end
    return error, catch_backtrace()
end

# We want to show an extra hint in case the error is of type `StackOverflowError`
function __inference_process_error(err::StackOverflowError, rethrow)
    @error """
    Stack overflow error occurred during the inference procedure. 
    The inference engine may execute message update rules recursively, hence, the model graph size might be causing this error. 
    To resolve this issue, try using `limit_stack_depth` inference option for model creation. See `?inference` documentation for more details.
    The `limit_stack_depth` option does not help against over stack overflow errors that might happening outside of the model creation or message update rules execution.
    """
    if rethrow
        Base.rethrow(err) # Shows the original stack trace
    end
    return err, catch_backtrace()
end

function __inference_check_itertype(::Symbol, ::Union{Nothing, Tuple, Vector})
    # This function check is the second argument is of type `Nothing`, `Tuple` or `Vector`. 
    # Does nothing is true, throws an error otherwise (see the second method below)
    nothing
end

function __inference_check_itertype(keyword::Symbol, ::T) where {T}
    error("""
          Keyword argument `$(keyword)` expects either `Tuple` or `Vector` as an input, but a value of type `$(T)` has been used.
          If you specify a `Tuple` with a single entry - make sure you put a trailing comma at then end, e.g. `(something, )`. 
          Note: Julia's parser interprets `(something)` and (something, ) differently. 
              The first expression simply ignores parenthesis around `something`. 
              The second expression defines `Tuple`with `something` as a first (and the last) entry.
          """)
end

function __infer_check_dicttype(::Symbol, ::Union{Nothing, NamedTuple, Dict, GraphPPL.VarDict})
    # This function check is the second argument is of type `Nothing`, `NamedTuple`, `Dict` or `VarDict`. 
    # Does nothing is true, throws an error otherwise (see the second method below)
    nothing
end

function __infer_check_dicttype(keyword::Symbol, ::T) where {T}
    error("""
          Keyword argument `$(keyword)` expects either `Dict` or `NamedTuple` as an input, but a value of type `$(T)` has been used.
          If you specify a `NamedTuple` with a single entry - make sure you put a trailing comma at then end, e.g. `(x = something, )`. 
          Note: Julia's parser interprets `(x = something)` and (x = something, ) differently. 
              The first expression defines (or **overwrites!**) the local/global variable named `x` with `something` as a content. 
              The second expression defines `NamedTuple` with `x` as a key and `something` as a value.
          """)
end

__inference_check_dataismissing(d) = (ismissing(d) || any(ismissing, d))

# Return NamedTuple for predictions
__inference_fill_predictions(s::Symbol, d::AbstractArray) = NamedTuple{Tuple([s])}([repeat([missing], length(d))])
__inference_fill_predictions(s::Symbol, d::DataVariable) = NamedTuple{Tuple([s])}([missing])

"""
    InferenceResult

This structure is used as a return value from the [`infer`](@ref) function. 

# Public Fields

- `posteriors`: `Dict` or `NamedTuple` of 'random variable' - 'posterior' pairs. See the `returnvars` argument for [`infer`](@ref).
- `free_energy`: (optional) An array of Bethe Free Energy values per VMP iteration. See the `free_energy` argument for [`infer`](@ref).
- `model`: `FactorGraphModel` object reference.
- `returnval`: Return value from executed `@model`.
- `error`: (optional) A reference to an exception, that might have occurred during the inference. See the `catch_exception` argument for [`infer`](@ref).

See also: [`infer`](@ref)
"""
struct InferenceResult{P, A, F, M, E}
    posteriors  :: P
    predictions :: A
    free_energy :: F
    model       :: M
    error       :: E
end

Base.iterate(results::InferenceResult)      = iterate((getfield(results, :posteriors), getfield(results, :predictions), getfield(results, :free_energy), getfield(results, :model), getfield(results, :returnval), getfield(results, :error)))
Base.iterate(results::InferenceResult, any) = iterate((getfield(results, :posteriors), getfield(results, :predictions), getfield(results, :free_energy), getfield(results, :model), getfield(results, :returnval), getfield(results, :error)), any)

issuccess(result::InferenceResult) = !iserror(result)
iserror(result::InferenceResult) = !isnothing(result.error)

function Base.show(io::IO, result::InferenceResult)
    print(io, "Inference results:\n")

    lcolumnlen = 18 # Defines the padding for the "left" column of the output

    print(io, rpad("  Posteriors", lcolumnlen), " | ")
    print(io, "available for (")
    join(io, keys(getfield(result, :posteriors)), ", ")
    print(io, ")\n")

    if !isempty(getfield(result, :predictions))
        print(io, rpad("  Predictions", lcolumnlen), " | ")
        print(io, "available for (")
        join(io, keys(getfield(result, :predictions)), ", ")
        print(io, ")\n")
    end

    if !isnothing(getfield(result, :free_energy))
        print(io, rpad("  Free Energy:", lcolumnlen), " | ")
        print(IOContext(io, :compact => true, :limit => true, :displaysize => (1, 80)), result.free_energy)
        print(io, "\n")
    end

    if iserror(result)
        print(
            io,
            "[ WARN ] An error has occurred during the inference procedure. The result might not be complete. You can use the `.error` field to access the error and its backtrace. Use `Base.showerror` function to display the error."
        )
    end
end

function Base.showerror(result::InferenceResult)
    return Base.showerror(stderr, result)
end

function Base.showerror(io::IO, result::InferenceResult)
    if iserror(result)
        error, backtrace = result.error
        println(io, error, "\n")
        show(io, "text/plain", stacktrace(backtrace))
    else
        print(io, "The inference has completed successfully.")
    end
end

function Base.getproperty(result::InferenceResult, property::Symbol)
    if property === :free_energy && getfield(result, :free_energy) === nothing
        error("""
              Bethe Free Energy has not been computed. 
              Use `free_energy = true` keyword argument for the `inference` function to compute Bethe Free Energy values.
              """)
    else
        return getfield(result, property)
    end
    return getfield(result, property)
end

__inference_invoke_callback(callback, args...)  = callback(args...)
__inference_invoke_callback(::Nothing, args...) = nothing

inference_invoke_callback(callbacks, name, args...) = __inference_invoke_callback(inference_get_callback(callbacks, name), args...)
inference_invoke_callback(::Nothing, name, args...) = nothing

inference_get_callback(callbacks, name) = get(() -> nothing, callbacks, name)
inference_get_callback(::Nothing, name) = nothing

unwrap_free_energy_option(option::Bool)                      = (option, Real)
unwrap_free_energy_option(option::Type{T}) where {T <: Real} = (true, T)

function __inference(;
    # `model` must be a materialized graph object from GraphPPL 
    model::ModelGenerator,
    # NamedTuple or Dict with data, optional if predictvars are specified
    data = nothing,
    # NamedTuple or Dict with initial marginals, optional, defaults to empty
    initmarginals = nothing,
    # NamedTuple or Dict with initial messages, optional, defaults to empty
    initmessages = nothing,  # optional
    # Constraints specification object
    constraints = nothing,
    # Meta specification object
    meta = nothing,
    # Model creation options
    options = nothing,
    # Return structure info, optional, defaults to return everything at each iteration
    returnvars = nothing,
    # Prediction structure info, optional, defaults to return everything at each iteration
    predictvars = nothing,
    # Number of iterations, defaults to 1, we do not distinguish between VMP or Loopy belief or EP iterations
    iterations = nothing,
    # Do we compute FE, optional, defaults to false 
    # Can be passed a floating point type, e.g. `Float64`, for better efficiency, but disables automatic differentiation packages, such as ForwardDiff.jl
    free_energy = false,
    # Default BFE stream checks
    free_energy_diagnostics = DefaultObjectiveDiagnosticChecks,
    # Show progress module, optional, defaults to false
    showprogress = false,
    # Inference cycle callbacks
    callbacks = nothing,
    # Addons specification
    addons = nothing,
    # Inference postprocessing option
    postprocess = DefaultPostprocess(),
    # warn, optional, defaults to true
    warn = true,
    # catch exceptions during the inference procedure, optional, defaults to false
    catch_exception = false
)
    _options = convert(ReactiveMPInferenceOptions, options)
    # If the `options` does not have `warn` key inside, override it with the keyword `warn`
    if isnothing(options) || !haskey(options, :warn)
        _options = setwarn(_options, warn)
    end

    # Override `options` addons if the `addons` keyword argument is present 
    if !isnothing(addons)
        if warn && !isnothing(getaddons(_options))
            @warn "Both `addons = ...` and `options = (addons = ..., )` specify a value for the `addons`. Ignoring the `options` setting. Set `warn = false` to supress this warning."
        end
        _options = setaddons(_options, addons)
    end

    # We create a model with the `GraphPPL` package and insert a certain RxInfer related 
    # plugins which include the VI plugin, meta plugin and the ReactiveMP integration plugin
    modelplugins = GraphPPL.PluginsCollection(GraphPPL.VariationalConstraintsPlugin(constraints), GraphPPL.MetaPlugin(meta), RxInfer.ReactiveMPInferencePlugin(_options))

    is_free_energy, S = unwrap_free_energy_option(free_energy)

    if is_free_energy
        fe_objective = BetheFreeEnergy(S)
        modelplugins = modelplugins + ReactiveMPFreeEnergyPlugin(fe_objective)
    end

    # The `_model` here still must be a `ModelGenerator`
    _model = GraphPPL.with_plugins(model, modelplugins)

    __infer_check_dicttype(:data, data)

    # If `predictvars` is specified implicitly as `KeepEach` or `KeepLast`, we replace it with the same value for each data variable
    if (predictvars === KeepEach() || predictvars === KeepLast())
        if !isnothing(data)
            predictoption = predictvars
            predictvars = Dict(variable => predictoption for (variable, value) in pairs(data))
        else # else we throw an error
            error("`predictvar` is specified as `$(predictvars)`, but `data` is not provided. Make sure to provide `data` or specify `predictvars` explicitly.")
        end
        # If `predictvar` is specified, but `data` is not, we initialize the `data` with missing values
    elseif !isnothing(predictvars) && isnothing(data)
        data = Dict(variable => missing for (variable, value) in pairs(predictvars))
        # If `predictvar` is not specified, but `data` is, we initialize the `predictvars` with `KeepLast` or `KeepEach` depending on the `iterations` value
        # But only if the data has missing values in it
    elseif isnothing(predictvars) && !isnothing(data)
        predictoption = iterations isa Number ? KeepEach() : KeepLast()
        predictvars = Dict(variable => predictoption for (variable, value) in pairs(data) if __inference_check_dataismissing(value))
        # If both `predictvar` and `data` are specified we double check if there are some entries in the `predictvars`
        # which are not specified in the `data` and inject them
        # We do the same the other way around for the `data` entries which are not specified in the `predictvars`
    elseif !isnothing(predictvars) && !isnothing(data)
        for (variable, _) in pairs(predictvars)
            if !haskey(data, variable)
                data = merge(data, Dict(variable => missing))
            end
        end
        for (variable, value) in pairs(data)
            if !haskey(predictvars, variable) && __inference_check_dataismissing(value)
                predictoption = iterations isa Number ? KeepEach() : KeepLast()
                predictvars = merge(predictvars, Dict(variable => predictoption))
            end
        end
    end

    __infer_check_dicttype(:predictvars, predictvars)

    inference_invoke_callback(callbacks, :before_model_creation)
    fmodel = create_model(_model | data)
    inference_invoke_callback(callbacks, :after_model_creation, fmodel)
    vardict = getvardict(fmodel)
    vardict = GraphPPL.variables(vardict) # TODO bvdmitri, should work recursively as well

    # First what we do - we check if `returnvars` is nothing or one of the two possible values: `KeepEach` and `KeepLast`. 
    # If so, we replace it with either `KeepEach` or `KeepLast` for each random and not-proxied variable in a model
    if isnothing(returnvars) || returnvars === KeepEach() || returnvars === KeepLast()
        # Checks if the first argument is `nothing`, in which case returns the second argument
        returnoption = something(returnvars, iterations isa Number ? KeepEach() : KeepLast())
        returnvars   = Dict(variable => returnoption for (variable, value) in pairs(vardict) if (israndom(value) && !isanonymous(value)))
    end

    __infer_check_dicttype(:returnvars, returnvars)

    # Use `__check_has_randomvar` to filter out unknown or non-random variables in the `returnvar` specification
    __check_has_randomvar(vardict, variable) = begin
        haskey_check   = haskey(vardict, variable)
        israndom_check = haskey_check ? israndom(vardict[variable]) : false
        if warn && !haskey_check
            @warn "`returnvars` object has `$(variable)` specification, but model has no variable named `$(variable)`. The `$(variable)` specification is ignored. Use `warn = false` to suppress this warning."
        elseif warn && haskey_check && !israndom_check
            @warn "`returnvars` object has `$(variable)` specification, but model has no **random** variable named `$(variable)`. The `$(variable)` specification is ignored. Use `warn = false` to suppress this warning."
        end
        return haskey_check && israndom_check
    end

    # Use `__check_has_prediction` to filter out unknown predictions variables in the `predictvar` specification
    __check_has_prediction(vardict, variable) = begin
        haskey_check = haskey(vardict, variable)
        isdata_check = haskey_check ? isdata(vardict[variable]) : false
        if warn && !haskey_check
            @warn "`predictvars` object has `$(variable)` specification, but model has no variable named `$(variable)`. The `$(variable)` specification is ignored. Use `warn = false` to suppress this warning."
        elseif warn && haskey_check && !isdata_check
            @warn "`predictvars` object has `$(variable)` specification, but model has no **data** variable named `$(variable)`. The `$(variable)` specification is ignored. Use `warn = false` to suppress this warning."
        end
        return haskey_check && isdata_check
    end

    # Second, for each random variable and predicting variable entry we create an actor
    actors_rv = Dict(variable => make_actor(vardict[variable], value) for (variable, value) in pairs(returnvars) if __check_has_randomvar(vardict, variable))
    actors_pr = Dict(variable => make_actor(vardict[variable], value) for (variable, value) in pairs(predictvars) if __check_has_prediction(vardict, variable))

    # At third, for each variable entry we create a boolean flag to track their updates
    updates = Dict(variable => MarginalHasBeenUpdated(false) for (variable, _) in pairs(merge(actors_rv, actors_pr)))

    _iterations = something(iterations, 1)
    _iterations isa Integer || error("`iterations` argument must be of type Integer or `nothing`")
    _iterations > 0 || error("`iterations` arguments must be greater than zero")

    fe_actor = nothing
    fe_subscription = VoidTeardown()

    potential_error = nothing
    executed_iterations = 0

    try
        on_marginal_update = inference_get_callback(callbacks, :on_marginal_update)
        subscriptions_rv   = Dict(variable => subscribe!(obtain_marginal(vardict[variable]) |> ensure_update(fmodel, on_marginal_update, variable, updates[variable]), actor) for (variable, actor) in pairs(actors_rv))
        subscriptions_pr   = Dict(variable => subscribe!(obtain_prediction(vardict[variable]) |> ensure_update(fmodel, on_marginal_update, variable, updates[variable]), actor) for (variable, actor) in pairs(actors_pr))

        if !isempty(actors_pr) && is_free_energy
            error("The Bethe Free Energy computation is not compatible with the prediction functionality. Set `free_energy = false` to suppress this error.")
        end

        if is_free_energy
            fe_actor        = ScoreActor(S, _iterations, 1)
            fe_subscription = subscribe!(score(fmodel, fe_objective, free_energy_diagnostics), fe_actor)
        end

        if !isnothing(initmarginals)
            for (variable, initvalue) in pairs(initmarginals)
                if haskey(vardict, variable)
                    assign_marginal!(vardict[variable], initvalue)
                elseif warn
                    @warn "`initmarginals` object has `$(variable)` specification, but model has no variable named `$(variable)`. Use `warn = false` to suppress this warning."
                end
            end
        end

        if !isnothing(initmessages)
            for (variable, initvalue) in pairs(initmessages)
                if haskey(vardict, variable)
                    assign_message!(vardict[variable], initvalue)
                elseif warn
                    @warn "`initmessages` object has `$(variable)` specification, but model has no variable named `$(variable)`. Use `warn = false` to suppress this warning."
                end
            end
        end

        if isnothing(data) || isempty(data)
            error("Data is empty. Make sure you used `data` keyword argument with correct value.")
        else
            foreach(filter(pair -> isdata(last(pair)) && !isanonymous(last(pair)), pairs(vardict))) do pair
                varname = first(pair)
                haskey(data, varname) || error(
                    "Data entry `$(varname)` is missing in `data` or `predictvars` arguments. Double check `data = ($(varname) = ???, )` or `predictvars = ($(varname) = ???, )`"
                )
            end
        end

        inference_invoke_callback(callbacks, :before_inference, fmodel)

        fdata = filter(pairs(data)) do pair
            hk      = haskey(vardict, first(pair))
            is_data = hk ? isdata(vardict[first(pair)]) : false
            if warn && (!hk || !is_data)
                @warn "`data` object has `$(first(pair))` specification, but model has no data input named `$(first(pair))`. Use `warn = false` to suppress this warning."
            end
            return hk && is_data
        end

        progress_meter = showprogress ? ProgressMeter.Progress(_iterations) : nothing
        cacheddatavars = Dict((key => getvariable(vardict[key]) for key in keys(fdata)))

        for iteration in 1:_iterations
            if something(ensure_bool_or_nothing(inference_invoke_callback(callbacks, :before_iteration, fmodel, iteration)), false)::Bool
                break
            end
            inference_invoke_callback(callbacks, :before_data_update, fmodel, data)
            for (key, value) in fdata
                update!(cacheddatavars[key], value)
            end
            inference_invoke_callback(callbacks, :after_data_update, fmodel, data)

            # Check that all requested marginals have been updated and unset the `updated` flag
            # Throws an error if some were not update
            __check_and_unset_updated!(updates)

            if !isnothing(progress_meter)
                ProgressMeter.next!(progress_meter)
            end

            executed_iterations += 1

            if something(ensure_bool_or_nothing(inference_invoke_callback(callbacks, :after_iteration, fmodel, iteration)), false)::Bool
                break
            end
        end

        for (_, subscription) in pairs(merge(subscriptions_pr, subscriptions_rv))
            unsubscribe!(subscription)
        end

        inference_invoke_callback(callbacks, :after_inference, fmodel)
    catch error
        potential_error = __inference_process_error(error, !catch_exception)
    end

    if !isnothing(fe_actor)
        release!(fe_actor, (_iterations === executed_iterations))
    end

    unsubscribe!(fe_subscription)

    posterior_values = Dict(variable => inference_postprocess(postprocess, getvalues(actor)) for (variable, actor) in pairs(actors_rv))
    predicted_values = Dict(variable => inference_postprocess(postprocess, getvalues(actor)) for (variable, actor) in pairs(actors_pr))
    fe_values        = !isnothing(fe_actor) ? score_snapshot_iterations(fe_actor, executed_iterations) : nothing

    return InferenceResult(posterior_values, predicted_values, fe_values, fmodel, potential_error)
end

function inference(; kwargs...)
    @warn "inference is deprecated and will be removed in the future. Use `infer` instead."
    return infer(; kwargs...)
end

include("autoupdates.jl")

"""
    RxInferenceEngine

The return value of the `infer` function in case of streamlined inference. 

# Public fields
- `posteriors`: `Dict` or `NamedTuple` of 'random variable' - 'posterior stream' pairs. See the `returnvars` argument for the [`infer`](@ref).
- `free_energy`: (optional) A stream of Bethe Free Energy values per VMP iteration. See the `free_energy` argument for the [`infer`](@ref).
- `history`: (optional) Saves history of previous marginal updates. See the `historyvars` and `keephistory` arguments for the [`infer`](@ref).
- `free_energy_history`: (optional) Free energy history, averaged across variational iterations value for all observations  
- `free_energy_raw_history`: (optional) Free energy history, returns returns computed values of all variational iterations for each data event (if available)
- `free_energy_final_only_history`: (optional) Free energy history, returns computed values of final variational iteration for each data event (if available)
- `events`: (optional) A stream of events send by the inference engine. See the `events` argument for the [`infer`](@ref).
- `model`: `ProbabilisticModel` object reference.

Use the `RxInfer.start(engine)` function to subscribe on the `datastream` source and start the inference procedure. 
Use `RxInfer.stop(engine)` to unsubscribe from the `datastream` source and stop the inference procedure. 
Note, that it is not always possible to start/stop the inference procedure.

See also: [`infer`](@ref), [`RxInferenceEvent`](@ref), [`RxInfer.start`](@ref), [`RxInfer.stop`](@ref)
"""
mutable struct RxInferenceEngine{T, D, L, V, P, H, S, U, A, FA, FS, R, I, M, N, X, E, J}
    datastream       :: D
    tickscheduler    :: L
    mainsubscription :: Teardown

    datavars   :: V
    posteriors :: P

    history::H
    historyactors::S
    historysubscriptions::Vector{Teardown}

    updateflags::U
    updatesubscriptions::Vector{Teardown}

    # auto updates
    autoupdates::A

    # free energy related
    fe_actor        :: FA
    fe_source       :: FS
    fe_subscription :: Teardown

    # utility 
    postprocess  :: R
    iterations   :: I
    model        :: M
    vardict      :: N
    events       :: E
    is_running   :: Bool
    is_errored   :: Bool
    is_completed :: Bool
    error        :: Any
    ticklock     :: J

    RxInferenceEngine(
        ::Type{T},
        datastream::D,
        tickscheduler::L,
        datavars::V,
        posteriors::P,
        updateflags::U,
        history::H,
        historyactors::S,
        autoupdates::A,
        fe_actor::FA,
        fe_source::FS,
        postprocess::R,
        iterations::I,
        model::M,
        vardict::N,
        enabledevents::Val{X},
        events::E,
        ticklock::J
    ) where {T, D, L, V, P, H, S, U, A, FA, FS, R, I, M, N, X, E, J} = begin
        return new{T, D, L, V, P, H, S, U, A, FA, FS, R, I, M, N, X, E, J}(
            datastream,
            tickscheduler,
            voidTeardown,
            datavars,
            posteriors,
            history,
            historyactors,
            Teardown[],
            updateflags,
            Teardown[],
            autoupdates,
            fe_actor,
            fe_source,
            voidTeardown,
            postprocess,
            iterations,
            model,
            vardict,
            events,
            false,
            false,
            false,
            nothing,
            ticklock
        )
    end
end

function Base.show(io::IO, engine::RxInferenceEngine)
    print(io, "RxInferenceEngine:\n")

    lcolumnlen = 22 # Defines the padding for the "left" column of the output

    print(io, rpad("  Posteriors stream", lcolumnlen), " | ")
    print(io, "enabled for (")
    join(io, keys(getfield(engine, :posteriors)), ", ")
    print(io, ")\n")

    print(io, rpad("  Free Energy stream", lcolumnlen), " | ")
    if !isnothing(getfield(engine, :fe_source))
        print(io, "enabled\n")
    else
        print(io, "disabled\n")
    end

    print(io, rpad("  Posteriors history", lcolumnlen), " | ")
    if !isnothing(getfield(engine, :historyactors))
        print(io, "available for (")
        join(io, keys(getfield(engine, :historyactors)), ", ")
        print(io, ")\n")
    else 
        print(io, "unavailable\n")
    end 

    print(io, rpad("  Free Energy history", lcolumnlen), " | ")
    if !isnothing(getfield(engine, :fe_actor))
        print(io, "available\n")
    else
        print(io, "unavailable\n")
    end

    print(io, rpad("  Enabled events", lcolumnlen), " | ")
    print(io, "[ ", join(enabled_events(engine), ", "), " ]")
end

enabled_events(::RxInferenceEngine{T, D, L, V, P, H, S, U, A, FA, FS, R, I, M, N, X, E}) where {T, D, L, V, P, H, S, U, A, FA, FS, R, I, M, N, X, E} = X

function Base.getproperty(result::RxInferenceEngine, property::Symbol)
    if property === :enabled_events
        return enabled_events(result)
    elseif property === :free_energy
        !isnothing(getfield(result, :fe_source)) ||
            error("Bethe Free Energy stream has not been created. Use `free_energy = true` keyword argument for the `rxinference` function to compute Bethe Free Energy values.")
        return getfield(result, :fe_source)
    elseif property === :free_energy_history
        !isnothing(getfield(result, :fe_actor)) || error(
            "Bethe Free Energy history has not been computed. Use `free_energy = true` keyword argument for the `rxinference` function to compute Bethe Free Energy values together with the `keephistory` argument."
        )
        return score_snapshot_iterations(getfield(result, :fe_actor))
    elseif property === :free_energy_final_only_history
        !isnothing(getfield(result, :fe_actor)) || error(
            "Bethe Free Energy history has not been comptued. Use `free_energy = true` keyword argument for the `rxinference` function to compute Bethe Free Energy values together with the `keephistory` argument."
        )
        return score_snapshot_final(getfield(result, :fe_actor))
    elseif property === :free_energy_raw_history
        !isnothing(getfield(result, :fe_actor)) || error(
            "Bethe Free Energy history has not been comptued. Use `free_energy = true` keyword argument for the `rxinference` function to compute Bethe Free Energy values together with the `keephistory` argument."
        )
        return score_snapshot(getfield(result, :fe_actor))
    end
    return getfield(result, property)
end

"""
    start(engine::RxInferenceEngine)

Starts the `RxInferenceEngine` by subscribing to the data source, instantiating free energy (if enabled) and starting the event loop.
Use [`RxInfer.stop`](@ref) to stop the `RxInferenceEngine`. Note that it is not always possible to stop/restart the engine and this depends on the data source type.

See also: [`RxInfer.stop`](@ref)
"""
function start(engine::RxInferenceEngine{T}) where {T}
    rxexecutorlock(engine.ticklock) do
        if engine.is_completed || engine.is_errored
            @warn "The engine has been completed or errored. Cannot start an exhausted engine."
            return nothing
        end

        if engine.is_running
            @warn "The engine is already running. Cannot start a single engine twice."
            return nothing
        end

        _enabled_events = engine.enabled_events
        _events         = engine.events

        inference_invoke_event(Val(:before_start), Val(_enabled_events), _events, engine)

        _eventexecutor = RxInferenceEventExecutor(T, engine)
        _tickscheduler = engine.tickscheduler

        # This subscription tracks updates of all `posteriors`
        engine.updatesubscriptions = map(keys(engine.updateflags), values(engine.updateflags)) do name, updateflag
            return subscribe!(obtain_marginal(engine.vardict[name]), updateflag)
        end

        if !isnothing(engine.historyactors) && !isnothing(engine.history)
            engine.historysubscriptions = map(keys(engine.historyactors), values(engine.historyactors)) do name, actor
                return subscribe!(obtain_marginal(engine.vardict[name]), actor)
            end
        end

        if !isnothing(engine.fe_actor)
            engine.fe_subscription = subscribe!(engine.fe_source, engine.fe_actor)
        end

        release!(_tickscheduler)

        engine.is_running = true

        # After all preparations we finaly can `subscribe!` on the `datastream`
        engine.mainsubscription = subscribe!(engine.datastream, _eventexecutor)

        inference_invoke_event(Val(:after_start), Val(_enabled_events), _events, engine)
    end

    return nothing
end

"""
    stop(engine::RxInferenceEngine)

Stops the `RxInferenceEngine` by unsubscribing to the data source, free energy (if enabled) and stopping the event loop.
Use [`RxInfer.start`](@ref) to start the `RxInferenceEngine` again. Note that it is not always possible to stop/restart the engine and this depends on the data source type.

See also: [`RxInfer.start`](@ref)
"""
function stop(engine::RxInferenceEngine)
    rxexecutorlock(engine.ticklock) do
        if engine.is_completed || engine.is_errored
            @warn "The engine has been completed or errored. Cannot stop an exhausted engine."
            return nothing
        end

        if !engine.is_running
            @warn "The engine is not running. Cannot stop an idle engine."
            return nothing
        end

        _enabled_events = engine.enabled_events
        _events         = engine.events

        inference_invoke_event(Val(:before_stop), Val(_enabled_events), _events, engine)

        unsubscribe!(engine.fe_subscription)
        unsubscribe!(engine.historysubscriptions)
        unsubscribe!(engine.updatesubscriptions)
        unsubscribe!(engine.mainsubscription)

        engine.is_running = false

        inference_invoke_event(Val(:after_stop), Val(_enabled_events), _events, engine)
    end

    return nothing
end

import Rocket: Actor, on_next!, on_error!, on_complete!

struct RxInferenceEventExecutor{T, E} <: Actor{T}
    engine::E

    RxInferenceEventExecutor(::Type{T}, engine::E) where {T, E} = new{T, E}(engine)
end

Base.show(io::IO, ::RxInferenceEventExecutor)         = print(io, "RxInferenceEventExecutor")
Base.show(io::IO, ::Type{<:RxInferenceEventExecutor}) = print(io, "RxInferenceEventExecutor")

rxexecutorlock(fn::F, ::Nothing) where {F} = fn()
rxexecutorlock(fn::F, locker) where {F}    = lock(fn, locker)

function Rocket.on_next!(executor::RxInferenceEventExecutor{T}, event::T) where {T}
    # This is the `main` executor of the inference procedure
    # It listens new data and is supposed to run indefinitely

    # By default `_ticklock` is nothing, `executorlock` is defined such that it does not sync if `_ticklock` is nothing
    _ticklock = executor.engine.ticklock

    rxexecutorlock(_ticklock) do

        # `executor.engine` is defined as mutable 
        # we extract all variables before the loop so Julia does not extract them every time
        _tickscheduler  = executor.engine.tickscheduler
        _iterations     = executor.engine.iterations
        _postprocess    = executor.engine.postprocess
        _model          = executor.engine.model
        _datavars       = executor.engine.datavars
        _autoupdates    = executor.engine.autoupdates
        _updateflags    = executor.engine.updateflags
        _history        = executor.engine.history
        _historyactors  = executor.engine.historyactors
        _fe_actor       = executor.engine.fe_actor
        _enabled_events = executor.engine.enabled_events
        _events         = executor.engine.events

        inference_invoke_event(Val(:on_new_data), Val(_enabled_events), _events, _model, event)

        # Before we start our iterations we 'prefetch' recent values for autoupdates
        fupdates = map(fetch, _autoupdates)

        # This loop correspond to the different VMP iterations
        # Here `_iterations` can be `Ref` too, so we use `[]`. Should not affect integers
        for iteration in 1:_iterations[]
            inference_invoke_event(Val(:before_iteration), Val(_enabled_events), _events, _model, iteration)

            # At first we update all our priors (auto updates) with the fixed values from the `redirectupdate` field
            inference_invoke_event(Val(:before_auto_update), Val(_enabled_events), _events, _model, iteration, _autoupdates)
            foreach(fupdates) do fupdate
                for (datavar, value) in fupdate
                    update!(datavar, value)
                end
            end
            inference_invoke_event(Val(:after_auto_update), Val(_enabled_events), _events, _model, iteration, _autoupdates)

            # At second we pass our observations
            inference_invoke_event(Val(:before_data_update), Val(_enabled_events), _events, _model, iteration, event)
            for (datavar, value) in zip(_datavars, values(event))
                update!(datavar, value)
            end
            inference_invoke_event(Val(:after_data_update), Val(_enabled_events), _events, _model, iteration, event)

            __check_and_unset_updated!(_updateflags)

            inference_invoke_event(Val(:after_iteration), Val(_enabled_events), _events, _model, iteration)
        end

        # `release!` on `fe_actor` ensures that free energy sumed up between iterations correctly
        if !isnothing(_fe_actor)
            release!(_fe_actor)
        end

        if !isnothing(_history) && !isnothing(_historyactors)
            inference_invoke_event(Val(:before_history_save), Val(_enabled_events), _events, _model)
            for (name, actor) in pairs(_historyactors)
                push!(_history[name], inference_postprocess(_postprocess, getvalues(actor)))
            end
            inference_invoke_event(Val(:after_history_save), Val(_enabled_events), _events, _model)
        end

        # On this `release!` call we update our priors for the next step
        release!(_tickscheduler)

        inference_invoke_event(Val(:on_tick), Val(_enabled_events), _events, _model)
    end
end

function Rocket.on_error!(executor::RxInferenceEventExecutor, err)
    _engine         = executor.engine
    _model          = executor.engine.model
    _enabled_events = executor.engine.enabled_events
    _events         = executor.engine.events

    _engine.is_errored = true
    _engine.error      = err

    inference_invoke_event(Val(:on_error), Val(_enabled_events), _events, _model, err)

    __inference_process_error(err)
end

function Rocket.on_complete!(executor::RxInferenceEventExecutor)
    _engine         = executor.engine
    _model          = executor.engine.model
    _enabled_events = executor.engine.enabled_events
    _events         = executor.engine.events

    _engine.is_completed = true

    inference_invoke_event(Val(:on_complete), Val(_enabled_events), _events, _model)

    return nothing
end

## 

"""
    RxInferenceEvent{T, D}

The `RxInferenceEngine` sends events in a form of the `RxInferenceEvent` structure. `T` represents the type of an event, `D` represents the type of a data associated with the event.
The type of data depends on the type of an event, but usually represents a tuple, which can be unrolled automatically with the Julia's splitting syntax, e.g. `model, iteration = event`. 
See the documentation of the `rxinference` function for possible event types and their associated data types.

The events system itself uses the `Rocket.jl` library API. For example, one may create a custom event listener in the following way:


```julia
using Rocket

struct MyEventListener <: Rocket.Actor{RxInferenceEvent}
    # ... extra fields
end

function Rocket.on_next!(listener::MyEventListener, event::RxInferenceEvent{ :after_iteration })
    model, iteration = event
    println("Iteration \$(iteration) has been finished.")
end

function Rocket.on_error!(listener::MyEventListener, err)
    # ...
end

function Rocket.on_complete!(listener::MyEventListener)
    # ...
end

```

and later on:

```julia
engine = infer(events = Val((:after_iteration, )), ...)

subscription = subscribe!(engine.events, MyEventListener(...))
```

See also: [`infer`](@ref), [`RxInferenceEngine`](@ref)
"""
struct RxInferenceEvent{T, D}
    data::D

    RxInferenceEvent(::Val{T}, data::D) where {T, D} = new{T, D}(data)
end

event_name(::RxInferenceEvent{T}) where {T} = T

Base.show(io::IO, ::RxInferenceEvent{T}) where {T} = print(io, "RxInferenceEvent(:", T, ")")

Base.iterate(event::RxInferenceEvent)        = iterate(event.data)
Base.iterate(event::RxInferenceEvent, state) = iterate(event.data, state)

function inference_invoke_event(::Val{Event}, ::Val{EnabledEvents}, events, args...) where {Event, EnabledEvents}
    # Here `E` must be a tuple of symbols
    if Event ∈ EnabledEvents
        next!(events, RxInferenceEvent(Val(Event), args))
    end
    return nothing
end

function __rxinference(;
    model::ModelGenerator,
    data = nothing,
    datastream = nothing,
    initmarginals = nothing,
    initmessages = nothing,
    autoupdates = nothing,
    constraints = nothing,
    meta = nothing,
    options = nothing,
    returnvars = nothing,
    historyvars = nothing,
    keephistory = nothing,
    iterations = nothing,
    free_energy = false,
    free_energy_diagnostics = DefaultObjectiveDiagnosticChecks,
    autostart = true,
    events = nothing,
    addons = nothing,
    callbacks = nothing,
    postprocess = DefaultPostprocess(),
    uselock = false,
    warn = true
)

    # In case if `data` is used we cast to a synchronous `datastream` with zip operator
    _datastream, _T = if isnothing(datastream) && !isnothing(data)
        __infer_check_dicttype(:data, data)

        names  = tuple(keys(data)...)
        items  = tuple(values(data)...)
        stream = labeled(Val(names), iterable(zip(items...)))
        etype  = NamedTuple{names, Tuple{eltype.(items)...}}

        stream, etype
    else
        eltype(datastream) <: NamedTuple || error("`eltype` of the `datastream` must be a `NamedTuple`")
        datastream, eltype(datastream)
    end

    datavarnames = fields(_T)::NTuple
    N            = length(datavarnames) # should be static

    _options = convert(ReactiveMPInferenceOptions, options)
    # If the `options` does not have `warn` key inside, override it with the keyword `warn`
    if isnothing(options) || !haskey(options, :warn)
        _options = setwarn(_options, warn)
    end

    # Override `options` addons if the `addons` keyword argument is present 
    if !isnothing(addons)
        if warn && !isnothing(getaddons(_options))
            @warn "Both `addons = ...` and `options = (addons = ..., )` specify a value for the `addons`. Ignoring the `options` setting. Set `warn = false` to supress this warning."
        end
        _options = setaddons(_options, addons)
    end

    # We create a model with the `GraphPPL` package and insert a certain RxInfer related 
    # plugins which include the VI plugin, meta plugin and the ReactiveMP integration plugin
    modelplugins = GraphPPL.PluginsCollection(GraphPPL.VariationalConstraintsPlugin(constraints), GraphPPL.MetaPlugin(meta), RxInfer.ReactiveMPInferencePlugin(_options))

    is_free_energy, S = unwrap_free_energy_option(free_energy)

    if is_free_energy
        fe_objective = BetheFreeEnergy(S)
        modelplugins = modelplugins + ReactiveMPFreeEnergyPlugin(fe_objective)
    end

    # The `_model` here still must be a `ModelGenerator`
    _model = GraphPPL.with_plugins(model, modelplugins)
    _autoupdates = something(autoupdates, ())

    # For each data entry and autoupdate we create a `DefferedDataHandler` handler for the `condition_on` structure 
    # We must do that because the data is not available at the moment of the model creation
    _condition_on = append_deffered_data_handlers((;), Tuple(Iterators.flatten((datavarnames, map(getlabels, _autoupdates)...))))

    inference_invoke_callback(callbacks, :before_model_creation)
    fmodel = create_model(_model | _condition_on)
    inference_invoke_callback(callbacks, :after_model_creation, fmodel)

    vardict = getvardict(fmodel)
    vardict = GraphPPL.variables(vardict) # TODO: Should work recursively as well

    _autoupdates = map((autoupdate) -> autoupdate(vardict), _autoupdates)

    # At the very beginning we try to preallocate handles for the `datavar` labels that are present in the `T` (from `datastream`)
    # This is not very type-stable-friendly but we do it once and it should pay-off in the inference procedure
    datavars = ntuple(N) do i
        datavarname = datavarnames[i]
        (haskey(vardict, datavarname) && is_data(vardict[datavarname])) ||
            error("The `datastream` produces data for `$(datavarname)`, but the model does not have a datavar named `$(datavarname)`")
        return getvariable(vardict[datavarname])
    end

    # If everything is ok with `datavars` and `redirectvars` next step is to initialise marginals and messages in the model
    # This happens only once at the creation, we do not reinitialise anything if the inference has been stopped and resumed with the `stop` and `start` functions
    if !isnothing(initmarginals)
        for (variable, initvalue) in pairs(initmarginals)
            if haskey(vardict, variable)
                assign_marginal!(vardict[variable], initvalue)
            elseif warn
                @warn "`initmarginals` object has `$(variable)` specification, but model has no variable named `$(variable)`. Use `warn = false` to suppress this warning."
            end
        end
    end

    if !isnothing(initmessages)
        for (variable, initvalue) in pairs(initmessages)
            if haskey(vardict, variable)
                assign_message!(vardict[variable], initvalue)
            elseif warn
                @warn "`initmessages` object has `$(variable)` specification, but model has no variable named `$(variable)`. Use `warn = false` to suppress this warning."
            end
        end
    end

    # `iterations` might be set to `nothing` in which case we assume `1` iteration
    _iterations = something(iterations, 1)
    (_iterations isa Integer || _iterations isa Ref{<:Integer}) || error("`iterations` argument must be of type Integer, Ref{<:Integer}, or `nothing`")
    _iterations[] > 0 || error("`iterations` arguments must be greater than zero")

    _keephistory = something(keephistory, 0)
    _keephistory isa Integer || error("`keephistory` argument must be of type Integer or `nothing`")
    _keephistory >= 0 || error("`keephistory` arguments must be greater than or equal to zero")

    # `tickscheduler` defines a moment when we send new posteriors in the `posteriors` streams
    tickscheduler = PendingScheduler()

    # Here we prepare our free energy streams (if requested)
    fe_actor  = nothing
    fe_source = nothing

    if is_free_energy
        if _keephistory > 0
            fe_actor = ScoreActor(S, _iterations[], _keephistory)
        end
        fe_source = score(fmodel, fe_objective, free_energy_diagnostics)
    end

    # Use `__check_has_randomvar` to filter out unknown or non-random variables in the `returnvars` and `historyvars` specification
    __check_has_randomvar(object, vardict, key) = begin
        haskey_check   = haskey(vardict, key)
        israndom_check = haskey_check ? israndom(vardict[key]) : false
        if warn && !haskey_check
            @warn "`$(object)` object has `$(key)` specification, but model has no variable named `$(key)`. The `$(key)` specification is ignored. Use `warn = false` to suppress this warning."
        elseif warn && haskey_check && !israndom_check
            @warn "`$(object)` object has `$(key)` specification, but model has no **random** variable named `$(key)`. The `$(key)` specification is ignored. Use `warn = false` to suppress this warning."
        end
        return haskey_check && israndom_check
    end

    # We check if `returnvars` argument is empty, in which case we return names of all random (non-proxy) variables in the model
    if isnothing(returnvars)
        returnvars = [variable for (variable, value) in pairs(vardict) if (israndom(value))]
    end

    eltype(returnvars) === Symbol || error("`returnvars` must contain a list of symbols") # TODO?

    returnvars = filter((varkey) -> __check_has_randomvar(:returnvars, vardict, varkey), returnvars)

    __inference_check_itertype(:returnvars, returnvars)

    # `rxinference` by default does not keep track of marginals updates history
    # If user specifies `keephistory` keyword argument
    if _keephistory > 0
        if isnothing(historyvars)
            # First what we do - we check if `historyvars` is nothing 
            # In which case we mirror the `returnvars` specication and use either `KeepLast()` or `KeepEach` (depending on the iterations spec)
            historyoption = _iterations[] > 1 ? KeepEach() : KeepLast()
            historyvars   = Dict(name => historyoption for name in returnvars)
        elseif historyvars === KeepEach() || historyvars === KeepLast()
            # Second we check if it is one of the two possible global values: `KeepEach` and `KeepLast`. 
            # If so, we replace it with either `KeepEach` or `KeepLast` for each random and not-proxied variable in a model
            historyvars = Dict(variable => historyvars for (variable, value) in pairs(vardict) if (israndom(value) && !isanonymous(value)))
        end

        historyvars = Dict((varkey => value) for (varkey, value) in pairs(historyvars) if __check_has_randomvar(:historyvars, vardict, varkey))

        __infer_check_dicttype(:historyvars, historyvars)
    else
        if !isnothing(historyvars) && warn
            @warn "`historyvars` keyword argument requires `keephistory > 0`. Ignoring `historyvars`. Use `warn = false` to suppress this warning."
            historyvars = nothing
        end
    end

    # Here we finally create structures for updates history 
    historyactors = nothing
    history       = nothing

    if !isnothing(historyvars) && _keephistory > 0
        historyactors = Dict(name => make_actor(vardict[name], historyoption, _iterations[]) for (name, historyoption) in pairs(historyvars))
        history       = Dict(name => CircularBuffer(_keephistory) for (name, _) in pairs(historyvars))
    end

    # At this point we must have properly defined and fixed `returnvars` and `historyvars` objects

    # For each random variable entry in `returnvars` specification we create a boolean flag to track their updates
    updateflags = Dict(variable => MarginalHasBeenUpdated(false) for variable in returnvars)

    # `posteriors` returns a `stream` for each entry in the `returnvars`
    posteriors = Dict(
        variable => obtain_marginal(vardict[variable]) |> schedule_on(tickscheduler) |> map(Any, (data) -> inference_postprocess(postprocess, data)) for variable in returnvars
    )

    _events        = Subject(RxInferenceEvent)
    _enabledevents = something(events, Val(()))

    if !(_enabledevents isa Val) || !(unval(_enabledevents) isa Tuple)
        error("`events` keyword argument must be a `Val` of tuple of symbols")
    elseif length(unval(_enabledevents)) > 0 && !(eltype(unval(_enabledevents)) === Symbol)
        error("`events` keyword argument must be a `Val` of tuple of symbols")
    end

    # By default we do not use any lock synchronization
    _ticklock = nothing

    # Check the lock
    if uselock === true
        _ticklock = Base.Threads.SpinLock()
    elseif uselock !== false # This check makes sense because `uselock` is not necessarily of the `Bool` type
        _ticklock = uselock
    end

    engine = RxInferenceEngine(
        _T,
        _datastream,
        tickscheduler,
        datavars,
        posteriors,
        updateflags,
        history,
        historyactors,
        _autoupdates,
        fe_actor,
        fe_source,
        postprocess,
        _iterations,
        fmodel,
        vardict,
        _enabledevents,
        _events,
        _ticklock
    )

    if autostart
        inference_invoke_callback(callbacks, :before_autostart, engine)
        start(engine)
        inference_invoke_callback(callbacks, :after_autostart, engine)
    end

    return engine
end

function rxinference(; kwargs...)
    @warn "The `rxinference` function is deprecated and will be removed in the future.  Use `infer` with the `autoupdates` keyword argument instead."

    infer(; kwargs...)
end

available_callbacks(::typeof(__inference)) = (
    :on_marginal_update,
    :before_model_creation,
    :after_model_creation,
    :before_inference,
    :before_iteration,
    :before_data_update,
    :after_data_update,
    :after_iteration,
    :after_inference
)

available_callbacks(::typeof(__rxinference)) = (:before_model_creation, :after_model_creation, :before_autostart, :after_autostart)

function __check_available_callbacks(warn, callbacks, available_callbacks)
    if warn && !isnothing(callbacks)
        for key in keys(callbacks)
            if warn && key ∉ available_callbacks
                @warn "Unknown callback specification: $(key). Available callbacks: $(available_callbacks). Set `warn = false` to supress this warning."
            end
        end
    end
end

"""
    infer(
        model; 
        data = nothing,
        datastream = nothing,
        autoupdates = nothing,
        initmarginals = nothing,
        initmessages = nothing,
        constraints = nothing,
        meta = nothing,
        options = nothing,
        returnvars = nothing, 
        predictvars = nothing, 
        historyvars = nothing,
        keephistory = nothing,
        iterations = nothing,
        free_energy = false,
        free_energy_diagnostics = DefaultObjectiveDiagnosticChecks,
        showprogress = false,
        callbacks = nothing,
        addons = nothing,
        postprocess = DefaultPostprocess(),
        warn = true,
        events = nothing,
        uselock = false,
        autostart = true,
        catch_exception = false
    )
This function provides a generic way to perform probabilistic inference for batch/static and streamline/online scenarios.
Returns an `InferenceResult` (batch setting) or `RxInferenceEngine` (streamline setting) based on the parameters used.

## Arguments

For more information about some of the arguments, please check below. 
- `model`: specifies a model generator, required
- `data`: `NamedTuple` or `Dict` with data, required (or `datastream` or `predictvars`)
- `datastream`: A stream of `NamedTuple` with data, required (or `data`)
- `autoupdates = nothing`: auto-updates specification, required for streamline inference, see `@autoupdates`
- `initmarginals = nothing`: `NamedTuple` or `Dict` with initial marginals, optional
- `initmessages = nothing`: `NamedTuple` or `Dict` with initial messages, optional
- `constraints = nothing`: constraints specification object, optional, see `@constraints`
- `meta  = nothing`: meta specification object, optional, may be required for some models, see `@meta`
- `options = nothing`: model creation options, optional, see `ModelInferenceOptions`
- `returnvars = nothing`: return structure info, optional, defaults to return everything at each iteration, see below for more information
- `predictvars = nothing`: return structure info, optional, see below for more information (exclusive for batch inference)
- `historyvars = nothing`: history structure info, optional, defaults to no history, see below for more information (exclusive for streamline inference)
- `keephistory = nothing`: history buffer size, defaults to empty buffer, see below for more information (exclusive for streamline inference)
- `iterations = nothing`: number of iterations, optional, defaults to `nothing`, the inference engine does not distinguish between variational message passing or Loopy belief propagation or expectation propagation iterations, see below for more information
- `free_energy = false`: compute the Bethe free energy, optional, defaults to false. Can be passed a floating point type, e.g. `Float64`, for better efficiency, but disables automatic differentiation packages, such as ForwardDiff.jl
- `free_energy_diagnostics = DefaultObjectiveDiagnosticChecks`: free energy diagnostic checks, optional, by default checks for possible `NaN`s and `Inf`s. `nothing` disables all checks.
- `showprogress = false`: show progress module, optional, defaults to false (exclusive for batch inference)
- `catch_exception`  specifies whether exceptions during the inference procedure should be caught, optional, defaults to false (exclusive for batch inference)
- `callbacks = nothing`: inference cycle callbacks, optional, see below for more info
- `addons = nothing`: inject and send extra computation information along messages, see below for more info
- `postprocess = DefaultPostprocess()`: inference results postprocessing step, optional, see below for more info
- `events = nothing`: inference cycle events, optional, see below for more info (exclusive for streamline inference)
- `uselock = false`: specifies either to use the lock structure for the inference or not, if set to true uses `Base.Threads.SpinLock`. Accepts custom `AbstractLock`. (exclusive for streamline inference)
- `autostart = true`: specifies whether to call `RxInfer.start` on the created engine automatically or not (exclusive for streamline inference)
- `warn = true`: enables/disables warnings

## Note on NamedTuples

When passing `NamedTuple` as a value for some argument, make sure you use a trailing comma for `NamedTuple`s with a single entry. The reason is that Julia treats `returnvars = (x = KeepLast())` and `returnvars = (x = KeepLast(), )` expressions differently. This first expression creates (or **overwrites!**) new local/global variable named `x` with contents `KeepLast()`. The second expression (note trailing comma) creates `NamedTuple` with `x` as a key and `KeepLast()` as a value assigned for this key.

The `model` argument accepts a `ModelGenerator` as its input. The easiest way to create the `ModelGenerator` is to use the `@model` macro. 
For example:

```julia
@model function coin_toss(some_argument, some_keyword_argument = 3)
    ...
end

result = infer(
    model = coin_toss(some_argument; some_keyword_argument = 3)
)
```

**Note**: The `model` keyword argument does not accept a `FactorGraphModel` instance as a value, as it needs to inject `constraints` and `meta` during the inference procedure.

- ### `data`
Either `data` or `datastream` or `predictvars` keyword argument is required. Specifying both `data` and `datastream` is not supported and will result in an error. Specifying both `datastream` and `predictvars` is not supported and will result in an error.

**Note**: The behavior of the `data` keyword argument depends on the inference setting (batch or streamline).

The `data` keyword argument must be a `NamedTuple` (or `Dict`) where keys (of `Symbol` type) correspond to all `datavar`s defined in the model specification. For example, if a model defines `x = datavar(Float64)` the 
`data` field must have an `:x` key (of `Symbol` type) which holds a value of type `Float64`. The values in the `data` must have the exact same shape as the `datavar` container. In other words, if a model defines `x = datavar(Float64, n)` then 
`data[:x]` must provide a container with length `n` and with elements of type `Float64`.

#### `streamline` setting

All entries in the `data` argument are zipped together with the `Base.zip` function to form one slice of the data chunck. This means all containers in the `data` argument must be of the same size (`zip` iterator finished as soon as one container has no remaining values).
In order to use a fixed value for some specific `datavar` it is not necessary to create a container with that fixed value, but rather more efficient to use `Iterators.repeated` to create an infinite iterator.

- ### `datastream`

The `datastream` keyword argument must be an observable that supports `subscribe!` and `unsubscribe!` functions (streams from the `Rocket.jl` package are also supported).
The elements of the observable must be of type `NamedTuple` where keys (of `Symbol` type) correspond to all `datavar`s defined in the model specification, except for those which are listed in the `autoupdates` specification. 
For example, if a model defines `x = datavar(Float64)` (which is not part of the `autoupdates` specification) the named tuple from the observable must have an `:x` key (of `Symbol` type) which holds a value of type `Float64`. The values in the named tuple must have the exact same shape as the `datavar` container. In other words, if a model defines `x = datavar(Float64, n)` then 
`namedtuple[:x]` must provide a container with length `n` and with elements of type `Float64`.

**Note**: The behavior of the individual named tuples from the `datastream` observable is similar to that which is used in the batch setting.
In fact, you can see the streamline inference as an efficient version of the batch inference, which automatically updates some `datavar`s with the `autoupdates` specification and listens to the `datastream` to update the rest of the `datavar`s.

For specific types of inference algorithms, such as variational message passing, it might be required to initialize (some of) the marginals before running the inference procedure in order to break the dependency loop. If this is not done, the inference algorithm will not be executed due to the lack of information and message and/or marginals will not be updated. In order to specify these initial marginals, you can use the `initmarginals` argument, such as
```julia
infer(...
    initmarginals = (
        # initialize the marginal distribution of x as a vague Normal distribution
        # if x is a vector, then it simply uses the same value for all elements
        # However, it is also possible to provide a vector of distributions to set each element individually 
        x = vague(NormalMeanPrecision),  
    ),
)

This argument needs to be a named tuple, i.e. `initmarginals = (a = ..., )`, or dictionary.

- ### `initmessages`

For specific types of inference algorithms, such as loopy belief propagation or expectation propagation, it might be required to initialize (some of) the messages before running the inference procedure in order to break the dependency loop. If this is not done, the inference algorithm will not be executed due to the lack of information and message and/or marginals will not be updated. In order to specify these initial messages, you can use the `initmessages` argument, such as
```julia
infer(...
    initmessages = (
        # initialize the messages distribution of x as a vague Normal distribution
        # if x is a vector, then it simply uses the same value for all elements
        # However, it is also possible to provide a vector of distributions to set each element individually 
        x = vague(NormalMeanPrecision),  
    ),
)

- ### `options`

- `limit_stack_depth`: limits the stack depth for computing messages, helps with `StackOverflowError` for some huge models, but reduces the performance of inference backend. Accepts integer as an argument that specifies the maximum number of recursive depth. Lower is better for stack overflow error, but worse for performance.
- `pipeline`: changes the default pipeline for each factor node in the graph
- `global_reactive_scheduler`: changes the scheduler of reactive streams, see Rocket.jl for more info, defaults to no scheduler

- ### `returnvars`

`returnvars` specifies latent variables of interest and their posterior updates. Its behavior depends on the inference type: streamline or batch.

**Batch inference:**
- Accepts a `NamedTuple` or `Dict` of return variable specifications.
- Two specifications available: `KeepLast` (saves the last update) and `KeepEach` (saves all updates).
- When `iterations` is set, returns every update for each iteration (equivalent to `KeepEach()`); if `nothing`, saves the last update (equivalent to `KeepLast()`).
- Use `iterations = 1` to force `KeepEach()` for a single iteration or set `returnvars = KeepEach()` manually.

Example:

```julia
result = infer(
    ...,
    returnvars = (
        x = KeepLast(),
        τ = KeepEach()
    )
)
```

Shortcut for setting the same option for all variables:

```julia
result = infer(
    ...,
    returnvars = KeepLast()  # or KeepEach()
)
```

**Streamline inference:**
- For each symbol in `returnvars`, `infer` creates an observable stream of posterior updates.
- Agents can subscribe to these updates using the `Rocket.jl` package.

Example:

```julia
engine = infer(
    ...,
    autoupdates = my_autoupdates,
    returnvars = (:x, :τ),
    autostart  = false
)
```

- ### `predictvars`

`predictvars` specifies the variables which should be predicted. In the model definition these variables are specified
as datavars, although they should not be passed inside data argument.

Similar to `returnvars`, `predictvars` accepts a `NamedTuple` or `Dict`. There are two specifications:
- `KeepLast`: saves the last update for a variable, ignoring any intermediate results during iterations
- `KeepEach`: saves all updates for a variable for all iterations

Example: 

```julia
result = infer(
    ...,
    predictvars = (
        o = KeepLast(),
        τ = KeepEach()
    )
)
```

**Note**: The `predictvars` argument is exclusive for batch setting.

- ### `historyvars`

`historyvars` specifies the variables of interests and the amount of information to keep in history about the posterior updates when performing streamline inference. The specification is similar to the `returnvars` when applied in batch setting.
The `historyvars` requires `keephistory` to be greater than zero.

`historyvars` accepts a `NamedTuple` or `Dict` or return var specification. There are two specifications:
- `KeepLast`: saves the last update for a variable, ignoring any intermediate results during iterations
- `KeepEach`: saves all updates for a variable for all iterations

Example: 

```julia
result = infer(
    ...,
    autoupdates = my_autoupdates,
    historyvars = (
        x = KeepLast(),
        τ = KeepEach()
    ),
    keephistory = 10
)
```

It is also possible to set either `historyvars = KeepLast()` or `historyvars = KeepEach()` that acts as an alias and sets the given option for __all__ random variables in the model.

# Example: 

```julia
result = infer(
    ...,
    autoupdates = my_autoupdates,
    historyvars = KeepLast(),
    keephistory = 10
)
```

- ### `keep_history`

Specifies the buffer size for the updates history both for the `historyvars` and the `free_energy` buffers in streamline inference.

- ### `iterations`

Specifies the number of variational (or loopy belief propagation) iterations. By default set to `nothing`, which is equivalent of doing 1 iteration. 

- ### `free_energy`

**Streamline inference:**

Specifies if the `infer` function should create an observable stream of Bethe Free Energy (BFE) values, computed at each VMP iteration.

- When `free_energy = true` and `keephistory > 0`, additional fields are exposed in the engine for accessing the history of BFE updates.
  - `engine.free_energy_history`: Averaged BFE history over VMP iterations.
  - `engine.free_energy_final_only_history`: BFE history of values computed in the last VMP iterations for each observation.
  - `engine.free_energy_raw_history`: Raw BFE history.

**Batch inference:**

Specifies if the `infer` function should return Bethe Free Energy (BFE) values.

- Optionally accepts a floating-point type (e.g., `Float64`) for improved BFE computation performance, but restricts the use of automatic differentiation packages.

- ### `free_energy_diagnostics`

This settings specifies either a single or a tuple of diagnostic checks for Bethe Free Energy values stream. By default checks for `NaN`s and `Inf`s. 
See also [`RxInfer.ObjectiveDiagnosticCheckNaNs`](@ref) and [`RxInfer.ObjectiveDiagnosticCheckInfs`](@ref).
Pass `nothing` to disable any checks.

- ### `catch_exception`

The `catch_exception` keyword argument specifies whether exceptions during the batch inference procedure should be caught in the `error` field of the 
result. By default, if exception occurs during the inference procedure the result will be lost. Set `catch_exception = true` to obtain partial result 
for the inference in case if an exception occurs. Use `RxInfer.issuccess` and `RxInfer.iserror` function to check if the inference completed successfully or failed.
If an error occurs, the `error` field will store a tuple, where first element is the exception itself and the second element is the caught `backtrace`. Use the `stacktrace` function 
with the `backtrace` as an argument to recover the stacktrace of the error. Use `Base.showerror` function to display
the error.

- ### `callbacks`

The inference function has its own lifecycle. The user is free to provide some (or none) of the callbacks to inject some extra logging or other procedures in the inference function, e.g.

```julia
result = infer(
    ...,
    callbacks = (
        on_marginal_update = (model, name, update) -> println("\$(name) has been updated: \$(update)"),
        after_inference    = (args...) -> println("Inference has been completed")
    )
)
```


The `callbacks` keyword argument accepts a named-tuple of 'name = callback' pairs. 
The list of all possible callbacks for different inference setting (batch or streamline) and their arguments is present below:

- `on_marginal_update`:    args: (model::FactorGraphModel, name::Symbol, update) (exlusive for batch inference)
- `before_model_creation`: args: ()
- `after_model_creation`:  args: (model::FactorGraphModel, returnval)
- `before_inference`:      args: (model::FactorGraphModel) (exlusive for batch inference)
- `before_iteration`:      args: (model::FactorGraphModel, iteration::Int)::Bool (exlusive for batch inference)
- `before_data_update`:    args: (model::FactorGraphModel, data) (exlusive for batch inference)
- `after_data_update`:     args: (model::FactorGraphModel, data) (exlusive for batch inference)
- `after_iteration`:       args: (model::FactorGraphModel, iteration::Int)::Bool (exlusive for batch inference)
- `after_inference`:       args: (model::FactorGraphModel) (exlusive for batch inference)
- `before_autostart`:      args: (engine::RxInferenceEngine) (exlusive for streamline inference)
- `after_autostart`:       args: (engine::RxInferenceEngine) (exlusive for streamline inference)

`before_iteration` and `after_iteration` callbacks are allowed to return `true/false` value.
`true` indicates that iterations must be halted and no further inference should be made.

- ### `addons`

The `addons` field extends the default message computation rules with some extra information, e.g. computing log-scaling factors of messages or saving debug-information.
Accepts a single addon or a tuple of addons. If set, replaces the corresponding setting in the `options`. Automatically changes the default value of the `postprocess` argument to `NoopPostprocess`.

- ### `postprocess`

The `postprocess` keyword argument controls whether the inference results must be modified in some way before exiting the `inference` function.
By default, the inference function uses the `DefaultPostprocess` strategy, which by default removes the `Marginal` wrapper type from the results.
Change this setting to `NoopPostprocess` if you would like to keep the `Marginal` wrapper type, which might be useful in the combination with the `addons` argument.
If the `addons` argument has been used, automatically changes the default strategy value to `NoopPostprocess`.

"""
function infer(;
    model::GraphPPL.ModelGenerator = nothing,
    data = nothing,
    datastream = nothing, # streamline specific
    autoupdates = nothing, # streamline specific
    initmarginals = nothing,
    initmessages = nothing,
    constraints = nothing,
    meta = nothing,
    options = nothing,
    returnvars = nothing,
    predictvars = nothing, # batch specific
    historyvars = nothing, # streamline specific
    keephistory = nothing, # streamline specific
    iterations = nothing,
    free_energy = false,
    free_energy_diagnostics = DefaultObjectiveDiagnosticChecks,
    showprogress = false, # batch specific
    catch_exception = false, # batch specific
    callbacks = nothing,
    addons = nothing,
    postprocess = DefaultPostprocess(), # streamline specific
    events = nothing, # streamline specific
    uselock = false, # streamline  specific
    autostart = true, # streamline specific
    warn = true
)
    if isnothing(model)
        error("The `model` keyword argument is required for the `infer` function.")
    elseif !isnothing(data) && !isnothing(datastream)
        error("""`data` and `datastream` keyword arguments cannot be used together. """)
    elseif isnothing(data) && isnothing(predictvars) && isnothing(datastream)
        error("""One of the keyword arguments `data` or `predictvars` or `datastream` must be specified""")
    end

    __infer_check_dicttype(:initmarginals, initmarginals)
    __infer_check_dicttype(:initmessages, initmessages)
    __infer_check_dicttype(:callbacks, callbacks)

    if isnothing(autoupdates)
        __check_available_callbacks(warn, callbacks, available_callbacks(__inference))
        __inference(
            model = model,
            data = data,
            initmarginals = initmarginals,
            initmessages = initmessages,
            constraints = constraints,
            meta = meta,
            options = options,
            returnvars = returnvars,
            predictvars = predictvars,
            iterations = iterations,
            free_energy = free_energy,
            free_energy_diagnostics = free_energy_diagnostics,
            showprogress = showprogress,
            callbacks = callbacks,
            addons = addons,
            postprocess = postprocess,
            warn = warn,
            catch_exception = catch_exception
        )
    else
        __check_available_callbacks(warn, callbacks, available_callbacks(__rxinference))
        __rxinference(
            model = model,
            data = data,
            datastream = datastream,
            autoupdates = autoupdates,
            initmarginals = initmarginals,
            initmessages = initmessages,
            constraints = constraints,
            meta = meta,
            options = options,
            returnvars = returnvars,
            historyvars = historyvars,
            keephistory = keephistory,
            iterations = iterations,
            free_energy = free_energy,
            free_energy_diagnostics = free_energy_diagnostics,
            autostart = autostart,
            callbacks = callbacks,
            addons = addons,
            postprocess = postprocess,
            warn = warn,
            events = events,
            uselock = uselock
        )
    end
end