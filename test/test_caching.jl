# invalidate native code cache in a system image if it has not been analyzed by JET
# yes this slows down anlaysis for sure, but otherwise JET will miss obvious errors like below
@testset "invalidate native code cache" begin
    interp, frame = profile_call((Nothing,)) do a
        a.field
    end
    @test length(interp.reports) === 1
end

@testset "integrate with global code cache" begin
    # analysis for `sum(::String)` is already cached, `sum′` and `sum′′` should use it
    let
        m = gen_virtual_module()
        interp, frame = Core.eval(m, quote
            sum′(s) = sum(s)
            sum′′(s) = sum′(s)
            $(profile_call)() do
                sum′′("julia")
            end
        end)
        test_sum_over_string(interp)
    end

    # incremental setup
    let
        m = gen_virtual_module()

        interp, frame = Core.eval(m, quote
            $(profile_call)() do
                sum("julia")
            end
        end)
        test_sum_over_string(interp)

        interp, frame = Core.eval(m, quote
            sum′(s) = sum(s)
            $(profile_call)() do
                sum′("julia")
            end
        end)
        test_sum_over_string(interp)

        interp, frame = Core.eval(m, quote
            sum′′(s) = sum′(s)
            $(profile_call)() do
                sum′′("julia")
            end
        end)
        test_sum_over_string(interp)
    end

    # should not error for virtual stacktrace traversing with a frame for inner constructor
    # https://github.com/aviatesk/JET.jl/pull/69
    let
        res, frame = @profile_toplevel begin
            struct Foo end
            println(Foo())
        end
        @test isempty(res.inference_error_reports)
    end
end

@testset "integrate with local code cache" begin
    let
        m = gen_virtual_module()
        interp, frame = Core.eval(m, quote
            struct Foo{T}
                bar::T
            end
            $(profile_call)((Foo{Int},)) do foo
                foo.baz # typo
            end
        end)

        @test !isempty(interp.reports)
        @test !isempty(interp.cache)
        @test haskey(interp.cache, Any[CC.Const(getproperty),m.Foo{Int},CC.Const(:baz)])
    end

    let
        m = gen_virtual_module()
        interp, frame = Core.eval(m, quote
            struct Foo{T}
                bar::T
            end
            getter(foo, prop) = getproperty(foo, prop)
            $(profile_call)((Foo{Int}, Bool)) do foo, cond
                getter(foo, :bar)
                cond ? getter(foo, :baz) : getter(foo, :qux) # non-deterministic typos
            end
        end)

        # there should be local cache for each errorneous constant analysis
        @test !isempty(interp.reports)
        @test !isempty(interp.cache)
        @test haskey(interp.cache, Any[CC.Const(m.getter),m.Foo{Int},CC.Const(:baz)])
        @test haskey(interp.cache, Any[CC.Const(m.getter),m.Foo{Int},CC.Const(:qux)])
    end
end
