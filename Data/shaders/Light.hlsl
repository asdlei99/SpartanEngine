/*
Copyright(c) 2016-2020 Panos Karabelas

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and / or sell
copies of the Software, and to permit persons to whom the Software is furnished
to do so, subject to the following conditions :

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/
							 
//= TEXTURES ==========================================
Texture2D tex_normal 					: register(t0);
Texture2D tex_material 					: register(t1);
Texture2D tex_depth 					: register(t2);
Texture2D tex_ssao 						: register(t3);
Texture2DArray light_depth_directional 	: register(t4);
TextureCube light_depth_point 			: register(t5);
Texture2D light_depth_spot 				: register(t6);
//=====================================================

//= INCLUDES =====================      
#include "BRDF.hlsl"              
#include "ShadowMapping.hlsl"
#include "VolumetricLighting.hlsl"
//================================

struct PixelOutputType
{
	float4 diffuse		: SV_Target0;
	float4 specular		: SV_Target1;
	float4 volumetric	: SV_Target2;
};

PixelOutputType mainPS(Pixel_PosUv input)
{
	PixelOutputType light_out;
	light_out.diffuse 		= 0.0f;
	light_out.specular 		= 0.0f;
	light_out.volumetric 	= 0.0f;
	float2 uv 				= input.uv;
	
	// Sample textures
	float4 normal_sample 	= tex_normal.Sample(sampler_point_clamp, uv);
	float4 material_sample  = tex_material.Sample(sampler_point_clamp, uv);
	float depth_sample   	= tex_depth.Sample(sampler_point_clamp, uv).r;
	float ssao_sample 		= tex_ssao.Sample(sampler_point_clamp, uv).r;
	
	// Post-proces samples	
	float3 normal	= normal_decode(normal_sample.xyz);
	float occlusion = normal_sample.w;
	occlusion 		= min(occlusion, ssao_sample);
	float metallic 	= material_sample.g;
    bool is_sky 	= material_sample.a == 0.0f;

	// Compute camera to pixel vector
    float3 position_world 	= get_position_from_depth(depth_sample, input.uv);
    float3 camera_to_pixel  = normalize(position_world - g_camera_position.xyz);
	
    // Fill in light struct with default values
    Light light;
    light.color 	            = color.xyz;
    light.position 	            = position.xyz;
    light.intensity 			= intensity_range_angle_bias.x;
    light.range 				= intensity_range_angle_bias.y;
    light.angle 				= intensity_range_angle_bias.z;
    light.bias					= intensity_range_angle_bias.w;
    light.normal_bias 			= normalBias_shadow_volumetric_contact.x;
    light.cast_shadows 		    = normalBias_shadow_volumetric_contact.y;
    light.cast_contact_shadows 	= normalBias_shadow_volumetric_contact.z;
    light.is_volumetric 	    = normalBias_shadow_volumetric_contact.w;
    light.distance_to_pixel     = length(position_world - light.position);
    #if DIRECTIONAL
    light.is_directional    = true;
    light.is_point          = false;
    light.is_spot           = false;
    light.direction	        = direction.xyz;
    light.array_size        = 4;
    #elif POINT
    light.is_directional    = false;
    light.is_point          = true;
    light.is_spot           = false;
    light.direction	        = normalize(position_world - light.position);
    light.array_size        = 6;
    #elif SPOT
    light.is_directional    = false;
    light.is_point          = false;
    light.is_spot           = true;
    light.direction	        = normalize(position_world - light.position);
    light.array_size        = 1;
    #endif
    
    // Volumetric lighting (requires shadow maps)
    [branch]
    if (light.cast_shadows && light.is_volumetric)
    {
        light_out.volumetric.rgb = VolumetricLighting(light, position_world, uv);
    }
    
    // Ignore sky (but after we have allowed for the volumetric light to affect it)
    if (is_sky)
    {
        return light_out;
    }
    
    // Shadow
    float shadow = 1.0f;
    {
        // Shadow mapping
        [branch]
        if (light.cast_shadows)
        {
            shadow = Shadow_Map(uv, normal, depth_sample, position_world, light);
        }
        
        // Screen space shadows
        [branch]
        if (light.cast_contact_shadows)
        {
            shadow = min(shadow, ScreenSpaceShadows(light, position_world, uv)); 
        }
    
        // Occlusion texture + SSAO
        shadow = min(shadow, occlusion);
        
        // Modulate light intensity
        light.intensity *= shadow;
    }
        
    // Save shadows in the diffuse's alpha channel (used to modulate IBL later)
    light_out.diffuse.a = shadow; // no longer used, changed texture format or use alpha for something else?
        
    #if POINT
        // Attunate
        float dist         = length(position_world - light.position);
        float attenuation  = saturate(1.0f - dist / light.range);
        light.intensity    *= attenuation * attenuation;
        
        // Erase light if there is no need to compute it
        light.intensity *= step(dist, light.range);
    #elif SPOT
        // Attunate
        float cutoffAngle   = 1.0f - light.angle;
        float dist          = length(position_world - light.position);
        float theta         = dot(direction.xyz, light.direction);
        float epsilon       = cutoffAngle - cutoffAngle * 0.9f;
        float attenuation 	= saturate((theta - cutoffAngle) / epsilon); // atteunate when approaching the outer cone
        attenuation         *= saturate(1.0f - dist / light.range);
        light.intensity 	*= attenuation * attenuation;
        
        // Erase light if there is no need to compute it
        light.intensity *= step(cutoffAngle, theta);
    #endif
    
    // Accumulate total light amount hitting that pixel (used to modulate ssr later)
    light_out.specular.a = light.intensity;
    
    // Diffuse color for BRDFs which will allow for diffuse and specular light to be multiplied by albedo later
    float3 diffuse_color = float3(1,1,1);
    
    // Create material
    Material material;
    material.roughness  		= material_sample.r;
    material.metallic   		= material_sample.g;
    material.emissive   		= material_sample.b;
    material.F0 				= lerp(0.04f, diffuse_color, material.metallic);
    
    // Reflectance equation
    [branch]
    if (light.intensity > 0.0f)
    {
        // Compute some stuff
        float3 l		= -light.direction;
        float3 v 		= -camera_to_pixel;
        float3 h 		= normalize(v + l);
        float v_dot_h 	= saturate(dot(v, h));
        float n_dot_v 	= saturate(dot(normal, v));
        float n_dot_l 	= saturate(dot(normal, l));
        float n_dot_h 	= saturate(dot(normal, h));
        float3 radiance	= light.color * light.intensity * n_dot_l;
    
        // BRDF components
        float3 F 			= 0.0f;
        float3 cDiffuse 	= BRDF_Diffuse(diffuse_color, material, n_dot_v, n_dot_l, v_dot_h);	
        float3 cSpecular 	= BRDF_Specular(material, n_dot_v, n_dot_l, n_dot_h, v_dot_h, F);
                
        // Ensure energy conservation
        float3 kS 	= F;							// The energy of light that gets reflected - Equal to Fresnel
        float3 kD 	= 1.0f - kS; 					// Remaining energy, light that gets refracted			
        kD 			*= 1.0f - material.metallic; 	// Multiply kD by the inverse metalness such that only non-metals have diffuse lighting		
        
        light_out.diffuse.rgb	= kD * cDiffuse * radiance;
        light_out.specular.rgb	= cSpecular * radiance;
    }
    

	return light_out;
}