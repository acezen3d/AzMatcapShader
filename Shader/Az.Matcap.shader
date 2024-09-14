Shader "Az/Matcap"
{
    Properties
    {
        [Header(Albedo and Matcap)]
        _MainTex ("MainTex", 2D) = "white" { }
        _Color ("Color", Color) = (1, 1, 1, 1)
        _MatcapTex ("MatcapTex", 2D) = "white" { }
        _MatcapColor ("MatcapColor", Color) = (1, 1, 1, 1)

        [Header(Matcap Normal Map)]
        _MatcapNormalMap ("MatcapNormalMap", 2D) = "bump" { }
        _MatcapNormalMapScale ("MatcapNormalMapScale", Range(0, 1)) = 1
        _MatcapNormalMapUVRotation ("MatcapNormalMapUVRotation", Range(-1, 1)) = 0

        [Header(Matcap Mask)]
        _MatcapFresnelPower ("MatcapFresnelPower", Range(0, 2)) = 0
        _MatcapMask ("MatcapMask", 2D) = "white" { }
        _MatcapMaskLevel ("MatcapMaskLevel", Range(-1, 1)) = 0

        [Header(Camera Rolling and Reflection)]
        [Toggle]_MatcapCancelCameraRolling ("MatcapCancelCameraRolling", Float) = 1
        [Toggle]_MatcapReflectionAdjustment ("MatcapReflectionAdjustment", Float) = 0

        [Header(Misc)]
        _MatcapUVRotation ("MatcapUVRotation", Range(-1, 1)) = 0
        [Enum(Normal, 0, Multiply, 1, Screen, 2, Overlay, 3, HardLight, 4, Darken, 5, Lighten, 6)]_MatcapBlendMode ("MatcapBlendMode", Float) = 0
        [IntRange]_MatcapBlurLevel ("MatcapBlurLevel", Range(0, 7)) = 0
        [Enum(Orthographic, 0, SphericalReflection, 1, ConstructingProjection, 2, CrossProduct, 3, RNMBlending, 4)] _MatcapUVMethod ("MatcapUVMethod", Float) = 0
    }

    SubShader
    {
        Tags { "RenderType" = "Opaque" "Queue" = "Geometry" "LightMode" = "Always" }
        LOD 100

        Pass
        {
            CGPROGRAM
            #pragma target 3.0
            #pragma vertex vert
            #pragma fragment frag

            #include "UnityCG.cginc"
            #include "Lighting.cginc"

            struct v2f
            {
                float4 pos : SV_POSITION;
                float2 uv : TEXCOORD0;
                float4 posWS : TEXCOORD1;
                float3 normalWS : TEXCOORD2;
                float4 tangentWS : TEXCOORD3;
            };

            sampler2D _MainTex;
            float4 _MainTex_ST;
            half4 _Color;
            sampler2D _MatcapTex;
            float4 _MatcapTex_ST;
            half4 _MatcapColor;

            sampler2D _MatcapNormalMap;
            float4 _MatcapNormalMap_ST;
            half _MatcapNormalMapScale;
            half _MatcapNormalMapUVRotation;

            half _MatcapFresnelPower;
            sampler2D _MatcapMask;
            float4 _MatcapMask_ST;
            half _MatcapMaskLevel;

            half _MatcapCancelCameraRolling;
            half _MatcapReflectionAdjustment;

            half _MatcapUVRotation;
            int _MatcapBlendMode;
            int _MatcapBlurLevel;
            int _MatcapUVMethod;

            //#region Utils

            float3 TangentSpaceNormalToWorldSpaceNormal(float3 normalWS, float4 tangentWS, float3 normalTS)
            {
                float3 binormalWS = cross(normalWS, tangentWS.xyz) * tangentWS.w * unity_WorldTransformParams.w;
                float3x3 tbn = transpose(float3x3(tangentWS.xyz, binormalWS, normalWS));
                return normalize(mul(tbn, normalTS));
            }

            float2 ScaleUV(float2 uv, float2 center, float2 scaling)
            {
                uv -= center;
                uv = mul(float2x2(scaling.x, 0.0, 0.0, scaling.y), uv);
                uv += center;
                return uv;
            }

            float2 RotateUV(float2 uv, float2 center, float rotation)
            {
                uv -= center;
                float s = sin(rotation);
                float c = cos(rotation);
                uv = mul(transpose(float2x2(c, -s, s, c)), uv); // Unity is left handed.
                uv += center;
                return uv;
            }

            float CameraRollDetection(out bool isMirror)
            {
                float3 cameraRight = UNITY_MATRIX_V[0].xyz;
                float3 cameraUp = UNITY_MATRIX_V[1].xyz;
                float3 cameraFront = UNITY_MATRIX_V[2].xyz;

                float3 crossFront = cross(cameraRight, cameraUp);
                isMirror = dot(crossFront, cameraFront) > 0.0; // Camera is facing negative z-axis, or UNITY_MATRIX_V defines a right-handed view space with the z-axis pointing towards the viewer.
                float3 cameraUpUnit = float3(0.0, 1.0, 0.0);
                float3 rightAxis = (isMirror ? - 1.0 : 1.0) * cross(cameraFront, cameraUpUnit);
                float cameraRollCos = dot(rightAxis, cameraRight) / (length(rightAxis) * length(cameraRight));
                float cameraRoll = acos(clamp(cameraRollCos, -1.0, 1.0));
                half cameraDir = cameraRight.y < 0.0 ? (isMirror ? - 1.0 : 1.0) : (isMirror ? 1.0 : - 1.0);
                return cameraDir * cameraRoll;
            }

            //#endregion

            //#region Matcap UV methods

            // Orthographic Sampling
            // This is the most conventional sampling, but it will have problems such as edge distortion.
            // https://medium.com/@kumokairo/world-space-matcap-shading-1d8f2a0ee296
            // https://github.com/KumoKairo/Worldspace-Normal-Lighting/blob/master/MatCap_Plain.shader
            // https://assetstore.unity.com/packages/vfx/shaders/matcapfx-4814
            // https://assetstore.unity.com/packages/vfx/shaders/free-matcap-shaders-8221
            // https://assetstore.unity.com/packages/vfx/shaders/hs-lightcap-free-lightning-fast-lighting-170240
            float2 MatcapUVMethod0(float3 normalVS)
            {
                return normalVS.xy * 0.5 + 0.5;
            }

            // Spherical Reflection Sampling
            // The reflection direction is calculated first in the perspective view, and the normal direction is calculated again in the orthogonal view.
            // https://www.opengl.org/archives/resources/code/samples/advanced/advanced97/notes/node93.html
            // https://www.clicktorelease.com/blog/creating-spherical-environment-mapping-shader/
            // https://zhuanlan.zhihu.com/p/84494845
            // https://blog.csdn.net/csuyuanxing/article/details/135039939
            // https://github.com/hughsk/matcap/blob/master/matcap.glsl
            float2 MatcapUVMethod1(float3 normalVS, float3 eyeVS)
            {
                float3 reflection = normalize(reflect(eyeVS, normalVS));
                float3 orthoNormal = reflection + float3(0.0, 0.0, 1.0);
                orthoNormal = normalize(orthoNormal);
                return orthoNormal.xy * 0.5 + 0.5;
            }

            // Constructing Projection Sampling
            // Three.js's approach. Using the upward positive y-axis of the camera, construct the tangent and binormal to project onto the view space normal direction.
            // https://blog.csdn.net/u012722551/article/details/105588501/
            // https://github.com/mrdoob/three.js/blob/dev/src/renderers/shaders/ShaderLib/meshmatcap.glsl.js
            float2 MatcapUVMethod2(float3 normalVS, float3 eyeVS)
            {
                float3 tangent = normalize(cross(eyeVS, float3(0.0, 1.0, 0.0)));
                float3 binormal = cross(normalize(-eyeVS), tangent);  // Has to be normalized again, otherwise the rounding error is more pronounced.
                return float2(dot(tangent, normalVS), dot(binormal, normalVS)) * 0.5 + 0.5;
            }

            // Cross Product Sampling
            // Simple construction of the cross product of the two.
            // https://zhuanlan.zhihu.com/p/478462422
            // https://godotshaders.com/shader/matcap-shader/
            // https://assetstore.unity.com/packages/vfx/shaders/omnishade-matcap-215222
            float2 MatcapUVMethod3(float3 normalVS, float3 eyeVS)
            {
                float3 viewCross = cross(normalVS, normalize(-eyeVS));
                return float2(-viewCross.y, viewCross.x) * 0.5 + 0.5;
            }

            // RNM Blending Sampling
            // Perturbation of the view space normal direction using the RNM normal blending.
            // https://github.com/unity3d-jp/UnityChanToonShaderVer2_Project/blob/release/legacy/2.0/Manual/UTS2_Manual_en.md#6-matcap--texture-projection-settings-menu
            // https://x.com/kanihira/status/1061448868221480960
            // https://blog.selfshadow.com/publications/blending-in-detail/
            // https://acegikmo.com/shaderforge/nodes/#normal%20blend
            float2 MatcapUVMethod4(float3 normalVS, float3 eyeVS)
            {
                float3 detail = normalVS * float3(-1.0, -1.0, 1.0);
                float3 base = normalize(-eyeVS) * float3(-1.0, -1.0, 1.0) + float3(0.0, 0.0, 1.0);
                float3 combined = base * dot(base, detail) / base.z - detail;
                return combined.xy * 0.5 + 0.5;
            }

            //#endregion

            v2f vert(appdata_tan v)
            {
                v2f o;
                o.pos = UnityObjectToClipPos(v.vertex);
                o.uv = v.texcoord;
                o.posWS = mul(unity_ObjectToWorld, v.vertex);
                o.normalWS = UnityObjectToWorldNormal(v.normal);
                o.tangentWS = float4(UnityObjectToWorldDir(v.tangent.xyz), v.tangent.w);
                return o;
            }

            half4 frag(v2f i) : SV_TARGET
            {
                float2 normalMapUV = RotateUV(i.uv, float2(0.5, 0.5), _MatcapNormalMapUVRotation * UNITY_PI);
                half3 normalTS = UnpackScaleNormal(tex2D(_MatcapNormalMap, TRANSFORM_TEX(normalMapUV, _MatcapNormalMap)), _MatcapNormalMapScale);
                float3 normalWS = TangentSpaceNormalToWorldSpaceNormal(i.normalWS, i.tangentWS, normalTS);

                float3 viewWS = normalize(_WorldSpaceCameraPos.xyz - i.posWS.xyz);
                float3 normalVS = mul((float3x3)UNITY_MATRIX_V, normalWS);
                float3 eyeVS = normalize(mul(UNITY_MATRIX_V, i.posWS));

                float2 matcapUV;
                if (_MatcapUVMethod == 1)
                {
                    matcapUV = MatcapUVMethod1(normalVS, eyeVS);
                }
                else if (_MatcapUVMethod == 2)
                {
                    matcapUV = MatcapUVMethod2(normalVS, eyeVS);
                }
                else if (_MatcapUVMethod == 3)
                {
                    matcapUV = MatcapUVMethod3(normalVS, eyeVS);
                }
                else if (_MatcapUVMethod == 4)
                {
                    matcapUV = MatcapUVMethod4(normalVS, eyeVS);
                }
                else
                {
                    matcapUV = MatcapUVMethod0(normalVS);
                }

                bool isMirror;
                float cameraRoll = CameraRollDetection(isMirror);
                float rotation;
                if (isMirror)
                {
                    rotation = _MatcapCancelCameraRolling
                    ? - _MatcapUVRotation * UNITY_PI - cameraRoll
                    : - _MatcapUVRotation * UNITY_PI - cameraRoll * 2.0;
                    rotation += _MatcapReflectionAdjustment * UNITY_PI;
                }
                else
                {
                    rotation = _MatcapCancelCameraRolling
                    ? _MatcapUVRotation * UNITY_PI + cameraRoll
                    : _MatcapUVRotation * UNITY_PI;
                }

                matcapUV = ScaleUV(matcapUV, float2(0.5, 0.5), _MatcapTex_ST.xy);
                matcapUV += _MatcapTex_ST.zw;
                matcapUV = RotateUV(matcapUV, float2(0.5, 0.5), rotation);
                matcapUV.x = isMirror ? 1.0 - matcapUV.x : matcapUV.x;

                half4 mainColor = tex2D(_MainTex, TRANSFORM_TEX(i.uv, _MainTex)) * _Color;
                half4 matcapColor = tex2Dlod(_MatcapTex, float4(matcapUV, 0.0, _MatcapBlurLevel)) * _MatcapColor;

                float nDotV = dot(normalWS, viewWS);
                float fresnel = pow(saturate(1.0 - nDotV), _MatcapFresnelPower) ;
                half matcapMask = tex2D(_MatcapMask, TRANSFORM_TEX(i.uv, _MatcapMask)).g;
                matcapMask = saturate(matcapMask + _MatcapMaskLevel);

                half4 finalColor;
                if (_MatcapBlendMode == 1)
                {
                    finalColor = mainColor * matcapColor;
                }
                else if (_MatcapBlendMode == 2)
                {
                    finalColor = 1.0 - (1.0 - mainColor) * (1.0 - matcapColor);
                }
                else if (_MatcapBlendMode == 3)
                {
                    finalColor = mainColor < 0.5 ? 2.0 * mainColor * matcapColor : 1.0 - 2.0 * (1.0 - mainColor) * (1.0 - matcapColor);
                }
                else if (_MatcapBlendMode == 4)
                {
                    finalColor = matcapColor < 0.5 ? 2.0 * mainColor * matcapColor : 1.0 - 2.0 * (1.0 - mainColor) * (1.0 - matcapColor);
                }
                else if (_MatcapBlendMode == 5)
                {
                    finalColor = min(mainColor, matcapColor);
                }
                else if (_MatcapBlendMode == 6)
                {
                    finalColor = max(mainColor, matcapColor);
                }
                else
                {
                    finalColor = matcapColor;
                }
                finalColor = lerp(mainColor, finalColor, matcapMask * fresnel);

                return half4(finalColor.rgb, 1.0);
            }

            ENDCG
        }
    }
    FallBack Off
}