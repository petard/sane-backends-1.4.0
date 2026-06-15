import cv2
import numpy as np
from iopaint.model_manager import ModelManager
from iopaint.schema import InpaintRequest

def inpaint_preserving_16bit(rgb_16bit_path, ir_16bit_path, output_16bit_path, film_type="color_negative", device='cuda'):
    """
    Cleans a Nikon Coolscan raw TIFF using its companion IR channel while preserving 16-bit depth.
    
    Parameters:
    - film_type: "color_negative", "slide", or "chromogenic_bw"
    """
    print(f"Loading 16-bit source files for [{film_type.upper()}] profile...")
    img_16bit = cv2.imread(rgb_16bit_path, cv2.IMREAD_UNCHANGED)
    ir_16bit = cv2.imread(ir_16bit_path, cv2.IMREAD_UNCHANGED)
    
    if img_16bit is None or ir_16bit is None:
        raise FileNotFoundError("Check your file paths. Could not load 16-bit TIFFs.")
        
    # 1. Create 8-bit versions strictly for the AI pipeline
    img_8bit = (img_16bit / 256).astype(np.uint8)
    ir_8bit = (ir_16bit / 256).astype(np.uint8)
    
    if len(ir_8bit.shape) == 3:
        ir_8bit = cv2.cvtColor(ir_8bit, cv2.COLOR_BGR2GRAY)

    # 2. Dynamically set thresholding logic based on film type
    # For Coolscan scanners, dust blocks light and registers as dark pixels
    if film_type == "color_negative":
        # Orange mask creates medium background levels on IR
        ir_threshold = 45
        dilation_iterations = 2
        _, mask = cv2.threshold(ir_8bit, ir_threshold, 255, cv2.THRESH_BINARY_INV)
        
    elif film_type == "slide":
        # High transparency allows more light, making dust boundaries sharper
        ir_threshold = 60
        dilation_iterations = 2
        _, mask = cv2.threshold(ir_8bit, ir_threshold, 255, cv2.THRESH_BINARY_INV)
        
    elif film_type == "chromogenic_bw":
        # Dye-based B&W film (e.g., XP2) often needs a sensitive threshold
        ir_threshold = 35
        dilation_iterations = 3
        _, mask = cv2.threshold(ir_8bit, ir_threshold, 255, cv2.THRESH_BINARY_INV)
        
    else:
        raise ValueError("Invalid film_type. Choose 'color_negative', 'slide', or 'chromogenic_bw'.")

    # 3. Dilate mask to catch the soft halos around dust grains
    kernel = np.ones((3, 3), np.uint8)
    mask = cv2.dilate(mask, kernel, iterations=dilation_iterations)

    # 4. Run IOPaint (LaMa) on the temporary 8-bit copy
    print(f"Initializing IOPaint (LaMa) on {device}...")
    model_manager = ModelManager(name="lama", device=device)
    config = InpaintRequest(ldm_steps=20, no_half=False)
    
    print("Inpainting dust zones using deep learning...")
    repaired_8bit = model_manager.inpaint(img_8bit, mask, config)

    # 5. Blend back into the original 16-bit data
    print("Blending AI repairs back into pristine 16-bit file structure...")
    blend_mask = mask.astype(np.float32) / 255.0
    blend_mask = cv2.GaussianBlur(blend_mask, (5, 5), 0)
    if len(img_16bit.shape) == 3:
        blend_mask = cv2.merge([blend_mask, blend_mask, blend_mask])

    repaired_16bit_patch = (repaired_8bit.astype(np.float32) * 256.0).astype(np.uint16)

    # Final composite calculation
    output_16bit = (img_16bit.astype(np.float32) * (1.0 - blend_mask) + 
                    repaired_16bit_patch.astype(np.float32) * blend_mask)
    output_16bit = np.clip(output_16bit, 0, 65535).astype(np.uint16)

    print(f"Saving pristine, restored 16-bit file to {output_16bit_path}...")
    cv2.imwrite(output_16bit_path, output_16bit, [cv2.IMWRITE_TIFF_COMPRESSION, 1])
    print("Process complete! High-bit depth integrity maintained.")

if __name__ == "__main__":
    # Example usage: Swap the film_type value as needed
    inpaint_preserving_16bit(
        rgb_16bit_path="coolscan_16bit_rgb.tif",
        ir_16bit_path="coolscan_16bit_ir.tif",
        output_16bit_path="restored_16bit_output.tif",
        film_type="color_negative", # "color_negative", "slide", or "chromogenic_bw"
        device="cuda"
    )
