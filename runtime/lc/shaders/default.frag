#version 450
layout(set=0,binding=0) uniform sampler2D image;
layout(location=0) in vec4 tint;
layout(location=1) in vec2 texcoord;
layout(location=0) out vec4 outputColor;
void main() { outputColor=texture(image,texcoord)*tint; }
