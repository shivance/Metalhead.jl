"""
    conv_norm(kernel_size, inplanes::Integer, outplanes::Integer, activation = relu;
              norm_layer = BatchNorm, revnorm::Bool = false, preact::Bool = false,
              use_norm::Bool = true, stride::Integer = 1, pad::Integer = 0,
              dilation::Integer = 1, groups::Integer = 1, [bias, weight, init])

    conv_norm(kernel_size, inplanes => outplanes, activation = identity;
              kwargs...)

Create a convolution + batch normalization pair with activation.

# Arguments

  - `kernel_size`: size of the convolution kernel (tuple)
  - `inplanes`: number of input feature maps
  - `outplanes`: number of output feature maps
  - `activation`: the activation function for the final layer
  - `norm_layer`: the normalization layer used
  - `revnorm`: set to `true` to place the normalisation layer before the convolution
  - `preact`: set to `true` to place the activation function before the batch norm
    (only compatible with `revnorm = false`)
  - `use_norm`: set to `false` to disable normalization
    (only compatible with `revnorm = false` and `preact = false`)
  - `stride`: stride of the convolution kernel
  - `pad`: padding of the convolution kernel
  - `dilation`: dilation of the convolution kernel
  - `groups`: groups for the convolution kernel
  - `bias`, `weight`, `init`: initialization for the convolution kernel (see [`Flux.Conv`](#))
"""
function conv_norm(kernel_size, inplanes::Integer, outplanes::Integer, activation = relu;
                   norm_layer = BatchNorm, revnorm::Bool = false, eps::Float32 = 1.0f-5,
                   preact::Bool = false, use_norm::Bool = true, kwargs...)
    # no normalization layer
    if !use_norm
        if preact || revnorm
            throw(ArgumentError("`preact` only supported with `use_norm = true`"))
        else
            # early return if no norm layer is required
            return [Conv(kernel_size, inplanes => outplanes, activation; kwargs...)]
        end
    end
    # channels for norm layer and activation functions for both conv and norm
    if revnorm
        activations = (conv = activation, bn = identity)
        normplanes = inplanes
    else
        activations = (conv = identity, bn = activation)
        normplanes = outplanes
    end
    # handle pre-activation
    if preact
        if revnorm
            throw(ArgumentError("`preact` and `revnorm` cannot be set at the same time"))
        else
            activations = (conv = activation, bn = identity)
        end
    end
    # layers
    layers = [Conv(kernel_size, inplanes => outplanes, activations.conv; kwargs...),
        norm_layer(normplanes, activations.bn; ϵ = eps)]
    return revnorm ? reverse(layers) : layers
end

function conv_norm(kernel_size, ch::Pair{<:Integer, <:Integer}, activation = identity;
                   kwargs...)
    inplanes, outplanes = ch
    return conv_norm(kernel_size, inplanes, outplanes, activation; kwargs...)
end

# conv + bn layer combination as used by the inception model family matching
# the default values used in TensorFlow
function basic_conv_bn(kernel_size, inplanes, outplanes, activation = relu; kwargs...)
    return conv_norm(kernel_size, inplanes, outplanes, activation; norm_layer = BatchNorm,
                     eps = 1.0f-3, bias = false, kwargs...)
end

"""
    dwsep_conv_bn(kernel_size, inplanes::Integer, outplanes::Integer,
                            activation = relu; norm_layer = BatchNorm,
                            revnorm::Bool = false, stride::Integer = 1,
                            use_norm::NTuple{2, Bool} = (true, true),
                            pad::Integer = 0, dilation::Integer = 1, [bias, weight, init])

Create a depthwise separable convolution chain as used in MobileNetv1.
This is sequence of layers:

  - a `kernel_size` depthwise convolution from `inplanes => inplanes`
  - a (batch) normalisation layer + `activation` (if `use_norm[1] == true`; otherwise
    `activation` is applied to the convolution output)
  - a `kernel_size` convolution from `inplanes => outplanes`
  - a (batch) normalisation layer + `activation` (if `use_norm[2] == true`; otherwise
    `activation` is applied to the convolution output)

See Fig. 3 in [reference](https://arxiv.org/abs/1704.04861v1).

# Arguments

  - `kernel_size`: size of the convolution kernel (tuple)
  - `inplanes`: number of input feature maps
  - `outplanes`: number of output feature maps
  - `activation`: the activation function for the final layer
  - `revnorm`: set to `true` to place the batch norm before the convolution
  - `use_norm`: a tuple of two booleans to specify whether to use normalization for the first and
    second convolution
  - `stride`: stride of the first convolution kernel
  - `pad`: padding of the first convolution kernel
  - `dilation`: dilation of the first convolution kernel
  - `bias`, `weight`, `init`: initialization for the convolution kernel (see [`Flux.Conv`](#))
"""
function dwsep_conv_bn(kernel_size, inplanes::Integer, outplanes::Integer,
                       activation = relu; eps::Float32 = 1.0f-5,
                       revnorm::Bool = false, stride::Integer = 1,
                       use_norm::NTuple{2, Bool} = (true, true), kwargs...)
    return vcat(conv_norm(kernel_size, inplanes, inplanes, activation; eps,
                          revnorm, use_norm = use_norm[1], stride,
                          groups = inplanes, kwargs...),
                conv_norm((1, 1), inplanes, outplanes, activation; eps,
                          revnorm, use_norm = use_norm[2]))
end

"""
    mbconv(kernel_size, inplanes::Integer, hidden_planes::Integer,
                     outplanes::Integer, activation = relu; stride::Integer,
                     reduction::Union{Nothing, Integer} = nothing)

    mbconv(kernel_size, inplanes::Integer, outplanes::Integer,
                     activation = relu; stride::Integer, expansion::Real,
                     reduction::Union{Nothing, Integer} = nothing)

Create a basic inverted residual block for MobileNet variants
([reference](https://arxiv.org/abs/1905.02244)).

# Arguments

  - `kernel_size`: kernel size of the convolutional layers
  - `inplanes`: number of input feature maps
  - `hidden_planes`: The number of feature maps in the hidden layer. Alternatively,
    specify the keyword argument `expansion`, which calculates the number of feature
    maps in the hidden layer from the number of input feature maps as:
    `hidden_planes = inplanes * expansion`
  - `outplanes`: The number of output feature maps
  - `activation`: The activation function for the first two convolution layer
  - `stride`: The stride of the convolutional kernel, has to be either 1 or 2
  - `reduction`: The reduction factor for the number of hidden feature maps
    in a squeeze and excite layer (see [`squeeze_excite`](#)).
"""
function mbconv(kernel_size, inplanes::Integer, hidden_planes::Integer,
                outplanes::Integer, activation = relu; stride::Integer,
                reduction::Union{Nothing, Integer} = nothing,
                norm_layer = BatchNorm)
    @assert stride in [1, 2] "`stride` has to be 1 or 2"
    layers = []
    # expand
    if inplanes != hidden_planes
        append!(layers,
                conv_norm((1, 1), inplanes, hidden_planes, activation; bias = false,
                          norm_layer))
    end
    # squeeze-excite layer
    if !isnothing(reduction)
        append!(layers,
                squeeze_excite(hidden_planes, inplanes ÷ reduction; activation,
                               gate_activation = hardσ))
    end
    # depthwise
    append!(layers,
            conv_norm(kernel_size, hidden_planes, hidden_planes, activation; bias = false,
                      norm_layer, stride, pad = SamePad(), groups = hidden_planes))
    # project
    append!(layers, conv_norm((1, 1), hidden_planes, outplanes, identity; bias = false))
    return stride == 1 && inplanes == outplanes ? SkipConnection(Chain(layers...), +) :
           Chain(layers...)
end

function fused_mbconv(kernel_size, inplanes::Integer, explanes::Integer, outplanes::Integer,
                      activation = relu; stride::Integer, norm_layer = BatchNorm)
    @assert stride in [1, 2] "`stride` has to be 1 or 2"
    layers = []
    if explanes != inplanes
        # fused expand
        append!(layers,
                conv_norm(kernel_size, inplanes, explanes, activation; norm_layer, stride))
        # project
        append!(layers, conv_norm((1, 1), explanes, outplanes, identity; norm_layer))
    else
        append!(layers,
                conv_norm((1, 1), inplanes, outplanes, activation; norm_layer, stride))
    end
    return stride == 1 && inplanes == outplanes ? SkipConnection(Chain(layers...), +) :
           Chain(layers...)
end
