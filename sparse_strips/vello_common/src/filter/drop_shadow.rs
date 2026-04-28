// Copyright 2026 the Vello Authors
// SPDX-License-Identifier: Apache-2.0 OR MIT

//! The drop shadow filter.

use crate::color::{AlphaColor, Srgb};
use crate::filter::gaussian_blur::{MAX_KERNEL_SIZE, plan_decimated_blur, transform_blur_params};
use crate::filter::transform_offset_params;
use crate::filter_effects::EdgeMode;
use crate::kurbo::Affine;

/// A drop shadow filter.
#[derive(Debug)]
pub struct DropShadow {
    /// The x-offset of the shadow.
    pub dx: f32,
    /// The y-offset of the shadow.
    pub dy: f32,
    /// The color of the shadow.
    pub color: AlphaColor<Srgb>,
    /// X-axis standard deviation for the blur (for reference/debugging).
    pub std_deviation_x: f32,
    /// Y-axis standard deviation for the blur (for reference/debugging).
    pub std_deviation_y: f32,
    /// Edge mode for blur sampling.
    pub edge_mode: EdgeMode,
    /// Number of 2x x-axis decimation levels to use.
    pub n_decimations_x: usize,
    /// Number of 2x y-axis decimation levels to use.
    pub n_decimations_y: usize,
    /// Pre-computed Gaussian kernel weights for the reduced x-axis blur.
    /// Only the first `kernel_size_x` elements are valid.
    pub kernel_x: [f32; MAX_KERNEL_SIZE],
    /// Pre-computed Gaussian kernel weights for the reduced y-axis blur.
    /// Only the first `kernel_size_y` elements are valid.
    pub kernel_y: [f32; MAX_KERNEL_SIZE],
    /// Actual length of the x-axis kernel.
    pub kernel_size_x: u8,
    /// Actual length of the y-axis kernel.
    pub kernel_size_y: u8,
}

impl DropShadow {
    /// Create a new drop shadow filter with the specified parameters.
    ///
    /// This precomputes the blur decimation plan and kernel for optimal performance.
    pub fn new(
        dx: f32,
        dy: f32,
        std_deviation_x: f32,
        std_deviation_y: f32,
        edge_mode: EdgeMode,
        color: AlphaColor<Srgb>,
    ) -> Self {
        let (n_decimations_x, kernel_x, kernel_size_x) = plan_decimated_blur(std_deviation_x);
        let (n_decimations_y, kernel_y, kernel_size_y) = plan_decimated_blur(std_deviation_y);

        Self {
            dx,
            dy,
            color,
            std_deviation_x,
            std_deviation_y,
            edge_mode,
            n_decimations_x,
            n_decimations_y,
            kernel_x,
            kernel_y,
            kernel_size_x,
            kernel_size_y,
        }
    }
}

/// Transform a drop shadow's offset and standard deviations using the affine transformation.
///
/// Applies the full linear transformation (rotation, scale, and shear) to the offset vector,
/// and scales the blur standard deviations.
///
/// # Arguments
/// * `dx` - Horizontal offset in user space
/// * `dy` - Vertical offset in user space
/// * `std_deviation_x` - X-axis blur standard deviation in user space
/// * `std_deviation_y` - Y-axis blur standard deviation in user space
/// * `transform` - The transformation matrix to apply
///
/// # Returns
/// A tuple of (`scaled_dx`, `scaled_dy`, `scaled_std_dev_x`, `scaled_std_dev_y`) in device space
pub(crate) fn transform_shadow_params(
    dx: f32,
    dy: f32,
    std_deviation_x: f32,
    std_deviation_y: f32,
    transform: &Affine,
) -> (f32, f32, f32, f32) {
    let (scaled_dx, scaled_dy) = transform_offset_params(dx, dy, transform);

    let (scaled_std_dev_x, scaled_std_dev_y) =
        transform_blur_params(std_deviation_x, std_deviation_y, transform);

    (scaled_dx, scaled_dy, scaled_std_dev_x, scaled_std_dev_y)
}
