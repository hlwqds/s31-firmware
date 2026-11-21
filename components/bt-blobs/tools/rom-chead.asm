
/tmp/chead.bin:     file format binary


Disassembly of section .data:

2f8127ec <.data>:
2f8127ec:	2f07f7b7          	lui	a5,0x2f07f
2f8127f0:	1f47a503          	lw	a0,500(a5) # 0x2f07f1f4
2f8127f4:	4785                	li	a5,1
2f8127f6:	00f50423          	sb	a5,8(a0)
2f8127fa:	415c                	lw	a5,4(a0)
2f8127fc:	04050fa3          	sb	zero,95(a0)
2f812800:	c791                	beqz	a5,0x2f81280c
2f812802:	00a54703          	lbu	a4,10(a0)
2f812806:	c319                	beqz	a4,0x2f81280c
2f812808:	55f5                	li	a1,-3
2f81280a:	8782                	jr	a5
2f81280c:	8082                	ret
2f81280e:	2f07f7b7          	lui	a5,0x2f07f
2f812812:	1f47a783          	lw	a5,500(a5) # 0x2f07f1f4
2f812816:	4705                	li	a4,1
2f812818:	04e78f23          	sb	a4,94(a5)
2f81281c:	8082                	ret
2f81281e:	09b0e2ef          	jal	t0,0x2f8210b8
2f812822:	892a                	mv	s2,a0
2f812824:	89ae                	mv	s3,a1
2f812826:	84b2                	mv	s1,a2
2f812828:	760020ef          	jal	0x2f814f88
2f81282c:	c131                	beqz	a0,0x2f812870
2f81282e:	2f07f7b7          	lui	a5,0x2f07f
2f812832:	1f47a403          	lw	s0,500(a5) # 0x2f07f1f4
2f812836:	00194783          	lbu	a5,1(s2)
2f81283a:	02100713          	li	a4,33
2f81283e:	04e78763          	beq	a5,a4,0x2f81288c
2f812842:	02200713          	li	a4,34
2f812846:	02e78863          	beq	a5,a4,0x2f812876
2f81284a:	1307                	.short	0x0713
