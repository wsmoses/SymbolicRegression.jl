module LossFunctionsModule

import Random: randperm, MersenneTwister
import LossFunctions: value, AggMode, SupervisedLoss
import ..CoreModule: Options, Dataset, Node
import ..EquationUtilsModule: compute_complexity
import ..EvaluateEquationModule: eval_tree_array, differentiable_eval_tree_array

function loss(
    x::AbstractArray{T}, y::AbstractArray{T}, options::Options{A,B,dA,dB,C,D}
)::T where {T<:Real,A,B,dA,dB,C<:SupervisedLoss,D}
    return value(options.loss, y, x, AggMode.Mean())
end
function loss(
    x::AbstractArray{T}, y::AbstractArray{T}, options::Options{A,B,dA,dB,C,D}
)::T where {T<:Real,A,B,dA,dB,C<:Function,D}
    return sum(options.loss.(x, y)) / length(y)
end

function loss(
    x::AbstractArray{T},
    y::AbstractArray{T},
    w::AbstractArray{T},
    options::Options{A,B,dA,dB,C,D},
)::T where {T<:Real,A,B,dA,dB,C<:SupervisedLoss,D}
    return value(options.loss, y, x, AggMode.WeightedMean(w))
end
function loss(
    x::AbstractArray{T},
    y::AbstractArray{T},
    w::AbstractArray{T},
    options::Options{A,B,dA,dB,C,D},
)::T where {T<:Real,A,B,dA,dB,C<:Function,D}
    return sum(options.loss.(x, y, w)) / sum(w)
end

# Evaluate the loss of a particular expression on the input dataset.
function eval_loss(tree::Node, dataset::Dataset{T}, options::Options)::T where {T<:Real}
    if options.noisy_nodes
        return eval_loss_noisy_nodes(tree, dataset, options)
    end

    (prediction, completion) = eval_tree_array(tree, dataset.X, options)

    if !completion
        return T(1000000000)
    end

    if dataset.weighted
        return loss(prediction, dataset.y, dataset.weights, options)
    else
        return loss(prediction, dataset.y, options)
    end
end

function mmd_loss(x::AbstractArray{T}, y::AbstractArray{T}, options::Options)::T where {T<:Real}
    # x: (feature, row)
    # y: (feature, row)
    n = size(x, 2)
    @assert n == size(y, 2)
    k_xx = zeros(T, n, n)
    k_yy = zeros(T, n, n)
    k_xy = zeros(T, n, n)
    mmd_kernel_width = options.noisy_kernel_width  # TODO: make this a parameter
    @inbounds for i in 1:n
        @inbounds @simd for j in 1:n
            k_xx[i, j] = exp(-sum((x[:, i] .- x[:, j]) .^ 2) / mmd_kernel_width)
            k_yy[i, j] = exp(-sum((y[:, i] .- y[:, j]) .^ 2) / mmd_kernel_width)
            k_xy[i, j] = exp(-sum((x[:, i] .- y[:, j]) .^ 2) / mmd_kernel_width)
        end
    end
    mmd_raw = sum(k_xx) + sum(k_yy) - 2 * sum(k_xy)
    mmd = mmd_raw / n^2
    return mmd
end

function eval_loss_noisy_nodes(
    tree::Node, dataset::Dataset{T}, options::Options
)::T where {T<:Real}
    @assert !dataset.weighted

    baseX = dataset.X
    # Settings for noise generation:
    num_noise_features = options.noisy_features
    num_seeds = 5

    losses = zeros(T, num_seeds)
    for noise_seed in 1:num_seeds

        # Current batch of noise:
        current_noise = randn(MersenneTwister(noise_seed), T, num_noise_features, dataset.n)
        # Noise enters as a feature:
        noisy_X = vcat(baseX, current_noise)
        (prediction, completion) = eval_tree_array(tree, noisy_X, options)
        if !completion
            return T(1000000000)
        end

        # We compare joint distribution of (x, y) to (x, y_predicted)
        z_true = vcat(noisy_X, reshape(dataset.y, (1, dataset.n)))
        z_predicted = vcat(noisy_X, reshape(prediction, (1, dataset.n)))

        losses[noise_seed] = mmd_loss(z_predicted, z_true, options)
    end
    return sum(losses) / num_seeds
end

# Compute a score which includes a complexity penalty in the loss
function loss_to_score(
    loss::T, baseline::T, tree::Node, options::Options
)::T where {T<:Real}
    normalized_loss_term = loss / baseline
    size = compute_complexity(tree, options)
    parsimony_term = size * options.parsimony

    return normalized_loss_term + parsimony_term
end

# Score an equation
function score_func(
    dataset::Dataset{T}, baseline::T, tree::Node, options::Options
)::Tuple{T,T} where {T<:Real}
    result_loss = eval_loss(tree, dataset, options)
    score = loss_to_score(result_loss, baseline, tree, options)
    return score, result_loss
end

# Score an equation with a small batch
function score_func_batch(
    dataset::Dataset{T}, baseline::T, tree::Node, options::Options
)::Tuple{T,T} where {T<:Real}
    batch_idx = randperm(dataset.n)[1:(options.batchSize)]
    batch_X = dataset.X[:, batch_idx]
    batch_y = dataset.y[batch_idx]
    (prediction, completion) = eval_tree_array(tree, batch_X, options)
    if !completion
        return T(1000000000), T(1000000000)
    end

    if !dataset.weighted
        result_loss = loss(prediction, batch_y, options)
    else
        batch_w = dataset.weights[batch_idx]
        result_loss = loss(prediction, batch_y, batch_w, options)
    end
    score = loss_to_score(result_loss, baseline, tree, options)
    return score, result_loss
end

end
