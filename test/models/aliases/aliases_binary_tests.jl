@testitem "aliases for binary operations" begin
    @model function binary_aliases_1(x, x1, x2, x3, x4)
        x ~ IMPLY(x1, AND(x2, OR(x3, NOT(x4))))
    end

    @model function binary_aliases_2(x, x1, x2, x3, x4)
        x ~ x1 -> x2 && x3 || ¬x4
    end

    @model function binary_aliases(y, aliases)
        x1 ~ Bernoulli(0.5)
        x2 ~ Bernoulli(0.5)
        x3 ~ Bernoulli(0.5)
        x4 ~ Bernoulli(0.5)
        x ~ aliases(x1 = x1, x2 = x2, x3 = x3, x4 = x4)
        x ~ Bernoulli(y)
    end

    function binary_aliases_inference(aliases)
        return infer(model = binary_aliases(aliases = aliases), data = (y = 0.5,), free_energy = true)
    end

    results = binary_aliases_inference(binary_aliases_1)
    # Here we simply test that it ran and gave some output 
    @test mean(results.posteriors[:x1]) ≈ 0.5
    @test first(results.free_energy) ≈ 0.6931471805599454

    @test_broken binary_aliases_inference(binary_aliases_2)
end
