# -*- coding: utf-8 -*-
"""แปลชื่อค่าจาก OBDb (ภาษาอังกฤษ) เป็นภาษาไทยแบบวลี
ถ้าแปลไม่ครบทุกคำ จะคืน None (แอปจะแสดงชื่ออังกฤษเดิม) เพื่อไม่ให้ได้ชื่อครึ่งไทยครึ่งอังกฤษที่อ่านยาก
"""
import re

# คำย่อที่ช่างไทยใช้ทับศัพท์อยู่แล้ว ปล่อยไว้ได้
KEEP = {
    'DPF', 'EGR', 'ATF', 'ECU', 'ECM', 'TCM', 'ABS', 'SRS', 'A/C', 'VVT', 'VVT-I', 'VVT-IE', 'VSS', 'MAP', 'MAF',
    'EGT', 'DPNR', 'PM', 'NOX', 'SCR', 'DEF', 'AFR', 'A/F', 'O2', 'B1S1', 'B1S2', 'B2S1', 'B2S2', 'MIL', 'DTC',
    'CVT', 'TCC', 'AT', 'MT', 'IG', 'ON', 'OFF', 'HV', 'EV', 'BMS', 'SOC', 'SOH', 'TPMS', 'ID', 'PCM', 'BCM',
    'VN', 'VGT', 'EVAP', 'ECT', 'IAT', 'TPS', 'APP', 'CAN', 'LIN', 'OBD', 'RPM', 'IPC', '12V', '14V', 'B+',
    'D1', 'D2', 'D3', 'D4', 'D5', 'D6', 'FL', 'FR', 'RL', 'RR', 'L/S', 'NTC', 'PWM', 'ISC', 'ETC', 'P/S', 'EPS',
    'SCV', 'HPFP', 'LPFP', 'DOC', 'TE1', 'C1', 'C3', 'MPI', 'T/F', '4WD', '2WD', 'AWD', 'DPF:',
}

# วลียาวก่อน (เรียงตามความยาวตอนใช้งาน)
PHRASES = {
    # DPF / ไอเสีย
    'diesel particulate and nitrogen oxide reduction regeneration status': 'สถานะการเผา DPNR',
    'diesel particulate filter differential pressure': 'แรงดันคร่อม DPF',
    'diesel particulate filter regeneration request mileage': 'ระยะที่ขอเผา DPF',
    'diesel particulate filter regeneration total count': 'จำนวนครั้งเผา DPF ทั้งหมด',
    'diesel particulate filter soot accumulation for distance': 'ระยะสะสมเขม่า DPF',
    'diesel particulate filter soot load, summation method': 'เขม่าใน DPF (วิธีคำนวณสะสม)',
    'diesel particulate filter soot pressure method, g/l': 'เขม่าใน DPF (วิธีวัดแรงดัน) g/L',
    'diesel particulate filter soot accumulation': 'เขม่าสะสมใน DPF',
    'diesel particulate filter accumulation level': 'ระดับเขม่าสะสมใน DPF',
    'diesel particulate filter soot': 'เขม่าใน DPF',
    'diesel particulate filter odometer': 'ระยะทางของ DPF',
    'diesel particulate filter temperature': 'อุณหภูมิ DPF',
    'diesel particulate filter, maximum temperature, previous': 'อุณหภูมิสูงสุด DPF ครั้งก่อน',
    'diesel particulate filter, maximum temperature': 'อุณหภูมิสูงสุด DPF',
    'pm accumulation ratio - bank 1': 'อัตราเขม่าสะสม (PM) แถว 1',
    'pm accumulation ratio': 'อัตราเขม่าสะสม (PM)',
    'particulate filter regeneration': 'การเผา DPF',
    'regeneration request soot deposit': 'ปริมาณเขม่าที่ขอเผา',
    'distance since last dpf regeneration': 'ระยะทางจากการเผา DPF ครั้งล่าสุด',
    'distance since last complete regeneration': 'ระยะทางจากการเผาครบครั้งล่าสุด',
    'exhaust gas temperature after turbo, before oxidation catalyst': 'อุณหภูมิไอเสียหลังเทอร์โบ ก่อนแคท',
    'exhaust gas temperature after dpf': 'อุณหภูมิไอเสียหลัง DPF',
    'exhaust gas temperature sensor': 'อุณหภูมิไอเสีย เซ็นเซอร์',
    'exhaust gas temperature': 'อุณหภูมิไอเสีย',
    'exhaust thermistor temperature': 'อุณหภูมิไอเสีย (เทอร์มิสเตอร์)',
    'exhaust back pressure': 'แรงดันย้อนกลับไอเสีย',
    'catalyst temperature': 'อุณหภูมิแคท',
    'pf differential pressure feedback egr sensor voltage': 'แรงดันไฟเซ็นเซอร์แรงดันคร่อม DPF/EGR',
    # EGR
    'exhaust gas recirculation cooler inlet temperature': 'อุณหภูมิขาเข้าคูลเลอร์ EGR',
    'exhaust gas recirculation cooler outlet temperature': 'อุณหภูมิขาออกคูลเลอร์ EGR',
    'exhaust gas recirculation valve position measured': 'ตำแหน่งวาล์ว EGR (วัดได้)',
    'exhaust gas recirculation valve position, desired': 'ตำแหน่งวาล์ว EGR (เป้าหมาย)',
    'exhaust gas recirculation valve duty': 'ดิวตี้วาล์ว EGR',
    'exhaust gas recirculation duty cycle': 'ดิวตี้วาล์ว EGR',
    'exhaust gas recirculation valve step': 'สเต็ปวาล์ว EGR',
    'exhaust gas recirculation step position': 'สเต็ปวาล์ว EGR',
    'exhaust gas recirculation throttle position signal': 'ตำแหน่งลิ้น EGR',
    'exhaust gas recirculation temperature': 'อุณหภูมิ EGR',
    'exhaust gas recirculation inlet temperature': 'อุณหภูมิขาเข้า EGR',
    'exhaust gas recirculation voltage': 'แรงดันไฟ EGR',
    'exhaust gas recirculation open': 'EGR เปิด',
    'exhaust gas recirculation': 'EGR',
    # หัวฉีด / น้ำมัน
    'injection feedback value': 'ค่าชดเชยหัวฉีด (Feedback) สูบ',
    'fuel injection volume control, cylinder': 'ปริมาณฉีดควบคุม สูบ',
    'fuel quantity correction, cylinder': 'ค่าชดเชยปริมาณฉีด สูบ',
    'fuel correction, cylinder': 'ค่าชดเชยน้ำมัน สูบ',
    'balance rate, cylinder': 'อัตราบาลานซ์หัวฉีด สูบ',
    'fuel injection, cylinder': 'การฉีดน้ำมัน สูบ',
    'injection volume per 10 injections, cylinder': 'ปริมาณฉีดต่อ 10 ครั้ง สูบ',
    'injection duration for cylinder': 'ระยะเวลาฉีด สูบ',
    'injector pulse width, cylinder': 'ความกว้างพัลส์หัวฉีด สูบ',
    'small injection quantity learning': 'ค่าเรียนรู้การฉีดปริมาณน้อย',
    'fuel injection amount at startup': 'ปริมาณฉีดตอนสตาร์ท',
    'fuel injection amount, pilot': 'ปริมาณฉีดนำ (pilot)',
    'fuel injection amount, main': 'ปริมาณฉีดหลัก',
    'fuel injection amount, after': 'ปริมาณฉีดตาม (after)',
    'fuel injection amount, post': 'ปริมาณฉีดหลัง (post)',
    'final fuel injection amount': 'ปริมาณฉีดสุดท้าย',
    'fuel injection duration, pilot': 'ระยะเวลาฉีดนำ (pilot)',
    'fuel injection duration, main': 'ระยะเวลาฉีดหลัก',
    'fuel injection timing': 'จังหวะฉีด',
    'fuel injection interval': 'ช่วงห่างการฉีด',
    'fuel injection impulse width': 'ความกว้างพัลส์ฉีด',
    'main injection timing': 'จังหวะฉีดหลัก',
    'main fuel injection quantity': 'ปริมาณฉีดหลัก',
    'injection amount, smoke limit': 'ปริมาณฉีดสูงสุด (จำกัดควัน)',
    'injection volume - target': 'ปริมาณฉีด (เป้าหมาย)',
    'injection volume total': 'ปริมาณฉีดรวม',
    'injection volume': 'ปริมาณฉีด',
    'injection quantity': 'ปริมาณฉีด',
    'injection mode': 'โหมดการฉีด',
    'injector pulse width': 'ความกว้างพัลส์หัวฉีด',
    'injector duty cycle': 'ดิวตี้หัวฉีด',
    'fuel quantity': 'ปริมาณน้ำมัน',
    'fuel compensation': 'ค่าชดเชยน้ำมัน',
    'fuel injection volume': 'ปริมาณฉีด',
    'target common rail fuel pressure': 'แรงดันรางหัวฉีด (เป้าหมาย)',
    'fuel rail pressure, desired': 'แรงดันรางหัวฉีด (เป้าหมาย)',
    'fuel rail pressure control': 'ค่าควบคุมแรงดันรางหัวฉีด',
    'fuel rail pressure': 'แรงดันรางหัวฉีด',
    'fuel rail sensor voltage, high pressure': 'แรงดันไฟเซ็นเซอร์รางหัวฉีด',
    'low side fuel rail pressure': 'แรงดันน้ำมันฝั่งแรงดันต่ำ',
    'high fuel pressure, actual': 'แรงดันรางหัวฉีด (จริง)',
    'high fuel pressure, target': 'แรงดันรางหัวฉีด (เป้าหมาย)',
    'fuel pressure, low actual': 'แรงดันน้ำมันฝั่งต่ำ (จริง)',
    'fuel pressure, low desired': 'แรงดันน้ำมันฝั่งต่ำ (เป้าหมาย)',
    'fuel pressure, low': 'แรงดันน้ำมันฝั่งต่ำ',
    'low fuel pressure': 'แรงดันน้ำมันฝั่งต่ำ',
    'fuel pressure': 'แรงดันน้ำมัน',
    'fuel temperature': 'อุณหภูมิน้ำมันเชื้อเพลิง',
    'fuel return temperature': 'อุณหภูมิน้ำมันไหลกลับ',
    'fuel filter temperature': 'อุณหภูมิกรองโซล่า',
    'fuel tank level': 'ระดับน้ำมันในถัง',
    'fuel level, volume': 'ปริมาณน้ำมันในถัง',
    'fuel level': 'ระดับน้ำมัน',
    'fuel remaining': 'น้ำมันคงเหลือ',
    'fuel meter': 'มาตรวัดน้ำมัน',
    'fuel consumption rate': 'อัตราสิ้นเปลืองน้ำมัน',
    'engine fuel rate': 'อัตราใช้น้ำมันเครื่องยนต์',
    'vehicle fuel rate': 'อัตราใช้น้ำมัน',
    'fuel pump duty cycle': 'ดิวตี้ปั๊มน้ำมัน',
    'fuel pump duty ratio': 'ดิวตี้ปั๊มน้ำมัน',
    'fuel trim, long term': 'ค่าปรับน้ำมันระยะยาว',
    'fuel trim, short term': 'ค่าปรับน้ำมันระยะสั้น',
    'long-term fuel trim': 'ค่าปรับน้ำมันระยะยาว',
    'short-term fuel trim': 'ค่าปรับน้ำมันระยะสั้น',
    'total fuel trim': 'ค่าปรับน้ำมันรวม',
    'dilution of oil with fuel': 'น้ำมันเชื้อเพลิงเจือจางน้ำมันเครื่อง',
    'fuel cut': 'ตัดน้ำมัน',
    # เทอร์โบ / ไอดี
    'boost pressure, actual': 'แรงดันบูสต์ (จริง)',
    'boost pressure: actual': 'แรงดันบูสต์ (จริง)',
    'boost pressure: desired': 'แรงดันบูสต์ (เป้าหมาย)',
    'boost pressure target': 'แรงดันบูสต์ (เป้าหมาย)',
    'boost pressure': 'แรงดันบูสต์',
    'turbo boost': 'แรงดันบูสต์',
    'boost': 'แรงดันบูสต์',
    'turbocharger, actual position': 'ตำแหน่งครีบเทอร์โบ (จริง)',
    'turbocharger, target position': 'ตำแหน่งครีบเทอร์โบ (เป้าหมาย)',
    'variable geometry turbo duty cycle': 'ดิวตี้เทอร์โบแปรผัน',
    'turbocharger outlet temperature': 'อุณหภูมิขาออกเทอร์โบ',
    'turbo inlet pressure': 'แรงดันขาเข้าเทอร์โบ',
    'intercooler coolant temperature': 'อุณหภูมิน้ำหล่อเย็นอินเตอร์คูลเลอร์',
    'charge air cooler temperature': 'อุณหภูมิอินเตอร์คูลเลอร์',
    'charge air temperature': 'อุณหภูมิอากาศอัด',
    'manifold absolute pressure': 'แรงดันท่อไอดี (MAP)',
    'manifold pressure': 'แรงดันท่อไอดี',
    'manifold air temperature': 'อุณหภูมิอากาศท่อไอดี',
    'manifold temperature': 'อุณหภูมิท่อไอดี',
    'intake air temperature': 'อุณหภูมิอากาศเข้า',
    'initial intake air temperature': 'อุณหภูมิอากาศเข้าตอนติดเครื่อง',
    'intake air': 'อากาศเข้า',
    'mass air flow': 'ปริมาณอากาศเข้า (MAF)',
    'air flow sensor voltage': 'แรงดันไฟเซ็นเซอร์ MAF',
    'throttle inlet pressure': 'แรงดันหน้าลิ้นเร่ง',
    'barometric pressure': 'ความกดอากาศ',
    'atmosphere pressure': 'ความกดอากาศ',
    # น้ำมันเครื่อง / ความร้อน
    'engine coolant temperature, ignition on': 'อุณหภูมิน้ำหล่อเย็นตอนบิดกุญแจ',
    'engine coolant temperature, initial': 'อุณหภูมิน้ำหล่อเย็นตอนติดเครื่อง',
    'initial engine coolant temperature': 'อุณหภูมิน้ำหล่อเย็นตอนติดเครื่อง',
    'engine coolant temperature': 'อุณหภูมิน้ำหล่อเย็น',
    'engine coolant temp': 'อุณหภูมิน้ำหล่อเย็น',
    'coolant temperature': 'อุณหภูมิน้ำหล่อเย็น',
    'coolant temp': 'อุณหภูมิน้ำหล่อเย็น',
    'calculated engine oil pressure': 'แรงดันน้ำมันเครื่อง (คำนวณ)',
    'calculated engine oil temperature': 'อุณหภูมิน้ำมันเครื่อง (คำนวณ)',
    'engine oil pressure: actual': 'แรงดันน้ำมันเครื่อง (จริง)',
    'engine oil pressure - desired': 'แรงดันน้ำมันเครื่อง (เป้าหมาย)',
    'engine oil pressure': 'แรงดันน้ำมันเครื่อง',
    'engine oil temperature': 'อุณหภูมิน้ำมันเครื่อง',
    'engine oil life remaining': 'อายุน้ำมันเครื่องคงเหลือ',
    'oil life remaining': 'อายุน้ำมันเครื่องคงเหลือ',
    'remaining oil life': 'อายุน้ำมันเครื่องคงเหลือ',
    'oil pressure': 'แรงดันน้ำมันเครื่อง',
    'oil temperature': 'อุณหภูมิน้ำมันเครื่อง',
    'sump oil temperature measured': 'อุณหภูมิน้ำมันในอ่าง',
    'distance since last oil change': 'ระยะทางจากเปลี่ยนน้ำมันเครื่อง',
    'distance since oil change': 'ระยะทางจากเปลี่ยนน้ำมันเครื่อง',
    'time since last oil change': 'เวลาจากเปลี่ยนน้ำมันเครื่อง',
    'cylinder head temperature': 'อุณหภูมิฝาสูบ',
    'cooling fan duty ratio': 'ดิวตี้พัดลมหม้อน้ำ',
    'cooling fan duty': 'ดิวตี้พัดลมหม้อน้ำ',
    'electric water pump rpm': 'รอบปั๊มน้ำไฟฟ้า',
    'electric water pump target speed': 'รอบปั๊มน้ำไฟฟ้า (เป้าหมาย)',
    'electric water pump': 'ปั๊มน้ำไฟฟ้า',
    # เกียร์
    'transmission fluid temperature, pan': 'อุณหภูมิน้ำมันเกียร์ (อ่าง)',
    'transmission fluid temperature, pipe': 'อุณหภูมิน้ำมันเกียร์ (ท่อ)',
    'transmission fluid temperature, filtered': 'อุณหภูมิน้ำมันเกียร์ (กรองสัญญาณ)',
    'transmission fluid post-converter temperature': 'อุณหภูมิน้ำมันเกียร์หลังทอร์คคอนเวอร์เตอร์',
    'transmission fluid temperature': 'อุณหภูมิน้ำมันเกียร์',
    'transmission fluid fluid quality': 'คุณภาพน้ำมันเกียร์',
    'transmission temperature, pan': 'อุณหภูมิน้ำมันเกียร์ (อ่าง)',
    'transmission temperature, torque converter': 'อุณหภูมิน้ำมันเกียร์ (ทอร์คคอนเวอร์เตอร์)',
    'transmission oil temperature': 'อุณหภูมิน้ำมันเกียร์',
    'transfer case fluid temperature': 'อุณหภูมิน้ำมันเกียร์ฝาก',
    'torque converter clutch slip speed': 'รอบสลิปคลัตช์ทอร์คคอนเวอร์เตอร์',
    'torque converter slip': 'สลิปทอร์คคอนเวอร์เตอร์',
    'torque converter turbine wheel speed': 'รอบเทอร์ไบน์ทอร์คคอนเวอร์เตอร์',
    'torque converter line pressure': 'แรงดันไลน์ทอร์คคอนเวอร์เตอร์',
    'transmission input shaft speed': 'รอบเพลาเข้าเกียร์',
    'transmission output shaft speed': 'รอบเพลาออกเกียร์',
    'input shaft speed': 'รอบเพลาเข้าเกียร์',
    'output shaft speed': 'รอบเพลาออกเกียร์',
    'input speed': 'รอบเพลาเข้าเกียร์',
    'output speed': 'รอบเพลาออกเกียร์',
    'turbine speed sensor voltage': 'แรงดันไฟเซ็นเซอร์รอบเทอร์ไบน์',
    'turbine speed': 'รอบเทอร์ไบน์',
    'knock feedback value': 'ค่าป้อนกลับการน็อก',
    'transmission gear ratio': 'อัตราทดเกียร์',
    'transmission gear': 'เกียร์ปัจจุบัน',
    'transmission odometer': 'ระยะทางของเกียร์',
    'transmission pressure, commanded': 'แรงดันเกียร์ (สั่ง)',
    'actual gear code': 'รหัสเกียร์ปัจจุบัน',
    'current gear': 'เกียร์ปัจจุบัน',
    'commanded gear': 'เกียร์ที่สั่ง',
    'shift gear': 'ตำแหน่งเกียร์',
    'gear ratio, commanded': 'อัตราทดเกียร์ (สั่ง)',
    'gear ratio': 'อัตราทดเกียร์',
    'gear, engaged': 'เกียร์ที่เข้า',
    'gear number': 'เกียร์ปัจจุบัน',
    'gear': 'เกียร์',
    'lock up state': 'สถานะล็อกอัพ',
    'lock-up solenoid': 'โซลินอยด์ล็อกอัพ',
    'lock-up control solenoid duty': 'ดิวตี้โซลินอยด์ล็อกอัพ',
    'line pressure control solenoid duty': 'ดิวตี้โซลินอยด์คุมแรงดันไลน์',
    'at position': 'ตำแหน่งคันเกียร์ออโต้',
    'shift time': 'เวลาเปลี่ยนเกียร์',
    'shift error': 'ค่าผิดพลาดการเปลี่ยนเกียร์',
    # เครื่องยนต์ทั่วไป
    'engine speed': 'รอบเครื่องยนต์',
    'engine rpm': 'รอบเครื่องยนต์',
    'average engine speed of all cylinders': 'รอบเครื่องเฉลี่ยทุกสูบ',
    'engine speed of cylinder': 'รอบเครื่องของสูบ',
    'desired idle speed': 'รอบเดินเบา (เป้าหมาย)',
    'target idle rpm': 'รอบเดินเบา (เป้าหมาย)',
    'engine load, actual': 'ภาระเครื่องยนต์ (จริง)',
    'engine load': 'ภาระเครื่องยนต์',
    'calculated load': 'ภาระเครื่องยนต์ (คำนวณ)',
    'absolute load': 'ภาระเครื่องยนต์สัมบูรณ์',
    'actual engine torque': 'แรงบิดเครื่องยนต์ (จริง)',
    'requested engine torque': 'แรงบิดเครื่องยนต์ (ที่ขอ)',
    'engine torque': 'แรงบิดเครื่องยนต์',
    'engine run time': 'เวลาเครื่องทำงาน',
    'engine starting time': 'เวลาสตาร์ทเครื่อง',
    'misfire count': 'จำนวนครั้งจุดระเบิดไม่สมบูรณ์',
    'all cylinders misfire count': 'misfire รวมทุกสูบ',
    'accelerator pedal position': 'ตำแหน่งคันเร่ง',
    'accelerator position': 'ตำแหน่งคันเร่ง',
    'accelerator pedal': 'คันเร่ง',
    'throttle position': 'ตำแหน่งลิ้นเร่ง',
    'throttle angle, actual': 'มุมลิ้นเร่ง (จริง)',
    'throttle angle, desired': 'มุมลิ้นเร่ง (เป้าหมาย)',
    'egr/vvt monitor': 'การทดสอบ EGR/VVT',
    # ไฟฟ้า
    '12v battery voltage': 'แรงดันแบตเตอรี่ 12V',
    '12v battery current': 'กระแสแบตเตอรี่ 12V',
    '12v battery state of charge': 'ประจุแบตเตอรี่ 12V',
    '12v battery temperature': 'อุณหภูมิแบตเตอรี่ 12V',
    'battery voltage': 'แรงดันแบตเตอรี่',
    'battery current': 'กระแสแบตเตอรี่',
    'battery temperature': 'อุณหภูมิแบตเตอรี่',
    'battery percentage, state of charge': 'ประจุแบตเตอรี่ (%)',
    'b+ battery voltage': 'แรงดันแบตเตอรี่ (B+)',
    '+bm voltage': 'แรงดันไฟ +BM',
    'alternator output duty cycle': 'ดิวตี้ไดชาร์จ',
    'alternator output duty': 'ดิวตี้ไดชาร์จ',
    'alternator current output': 'กระแสไดชาร์จ',
    'module voltage': 'แรงดันไฟกล่อง',
    'engine control module voltage': 'แรงดันไฟกล่องเครื่อง',
    'dashboard voltage': 'แรงดันไฟหน้าปัด',
    # ระยะทาง / ความเร็ว
    'vehicle speed': 'ความเร็วรถ',
    'odometer': 'เลขไมล์',
    'vehicle odometer': 'เลขไมล์',
    'total distance, lifetime': 'ระยะทางรวม',
    'trip distance': 'ระยะทางทริป',
    'distance since dtc clear': 'ระยะทางจากลบรหัส',
    'distance with mil': 'ระยะทางที่ไฟเตือนติด',
    'distance to empty': 'ระยะทางที่วิ่งได้',
    'distance since last battery cable disconnection': 'ระยะทางจากถอดขั้วแบตครั้งล่าสุด',
    'wheel speed': 'ความเร็วล้อ',
    'front left wheel speed': 'ความเร็วล้อหน้าซ้าย',
    'front right wheel speed': 'ความเร็วล้อหน้าขวา',
    'rear left wheel speed': 'ความเร็วล้อหลังซ้าย',
    'rear right wheel speed': 'ความเร็วล้อหลังขวา',
    'front left tire pressure': 'ลมยางหน้าซ้าย',
    'front right tire pressure': 'ลมยางหน้าขวา',
    'rear left tire pressure': 'ลมยางหลังซ้าย',
    'rear right tire pressure': 'ลมยางหลังขวา',
    'spare tire pressure': 'ลมยางอะไหล่',
    'tire pressure': 'ลมยาง',
    'tire temperature': 'อุณหภูมิยาง',
    'lateral acceleration': 'ความเร่งด้านข้าง',
    'yaw rate': 'อัตราการหมุนตัวรถ',
    'steering wheel angle': 'มุมพวงมาลัย',
    'brake pedal': 'แป้นเบรก',
    'brake switch': 'สวิตช์เบรก',
    'master cylinder sensor temperature': 'อุณหภูมิเซ็นเซอร์แม่ปั๊มเบรก',
    'brake booster pressure': 'แรงดันหม้อลมเบรก',
    # แอร์
    'ambient air temperature': 'อุณหภูมิอากาศภายนอก',
    'ambient temperature': 'อุณหภูมิภายนอก',
    'outside air temperature': 'อุณหภูมิภายนอก',
    'interior temperature': 'อุณหภูมิในห้องโดยสาร',
    'cabin temperature': 'อุณหภูมิในห้องโดยสาร',
    'a/c refrigerant pressure': 'แรงดันน้ำยาแอร์',
    'a/c compressor pressure': 'แรงดันน้ำยาแอร์',
    'air conditioning high side pressure': 'แรงดันน้ำยาแอร์ฝั่งสูง',
    'air conditioning pressure': 'แรงดันน้ำยาแอร์',
    'evaporator fin thermistor': 'อุณหภูมิตู้แอร์ (ครีบอีวาฯ)',
    'evaporator target temp': 'อุณหภูมิตู้แอร์ (เป้าหมาย)',
    'blower motor speed level': 'ระดับพัดลมแอร์',
    'solar sensor': 'เซ็นเซอร์แสงแดด',
    'air temperature sensor': 'เซ็นเซอร์อุณหภูมิอากาศ',
    # อื่น ๆ
    'check engine': 'ไฟเช็คเอนจิ้น',
    'cruise control speed': 'ความเร็วครูสคอนโทรล',
    'cruise control status': 'สถานะครูสคอนโทรล',
    '4 wheel drive engaged': 'เข้าขับเคลื่อน 4 ล้อ',
}

WORDS = {
    'cylinder': 'สูบ', 'bank': 'แถว', 'sensor': 'เซ็นเซอร์', 'number': 'ตัวที่', 'variant': 'แบบ',
    'variation': 'แบบ', 'var.': 'แบบ ', 'alternate': 'สำรอง', 'previous trip': 'ทริปก่อน', 'actual': 'จริง', 'desired': 'เป้าหมาย',
    'target': 'เป้าหมาย', 'commanded': 'สั่ง', 'pilot': 'นำ', 'post': 'หลัง', 'main': 'หลัก', 'left': 'ซ้าย',
    'right': 'ขวา', 'front': 'หน้า', 'rear': 'หลัง', 'driver': 'คนขับ', 'passenger': 'ผู้โดยสาร',
    'high resolution': 'ละเอียดสูง', 'raw count': 'ค่าดิบ', 'voltage': 'แรงดันไฟ', 'temperature': 'อุณหภูมิ',
    'pressure': 'แรงดัน', 'current': 'กระแส', 'speed': 'ความเร็ว', 'duty': 'ดิวตี้', 'status': 'สถานะ',
}

ALLOWED = re.compile(r"^[0-9\.\-%°:/()+,#\s]*$")


def _norm(s):
    s = s.strip()
    s = re.sub(r'\s+', ' ', s)
    return s


def translate(name):
    """คืนชื่อไทย หรือ None ถ้าแปลไม่ครบ"""
    src = _norm(name)
    low = src.lower()
    # "Cylinder 1 fuel compensation" → "fuel compensation, cylinder 1"
    m = re.match(r'^cylinder\s*#?\s*(\d+)\s+(.+)$', low)
    if m:
        low = f'{m.group(2)}, cylinder {m.group(1)}'
    out = low
    # วลี (ยาวก่อน)
    for en in sorted(PHRASES, key=len, reverse=True):
        th = PHRASES[en]
        pat = r'(?<![a-z])' + re.escape(en) + r'(?![a-z])'
        out = re.sub(pat, '\u0000' + th + '\u0001', out)
    # คำเดี่ยวที่เหลือ (เฉพาะคำที่อยู่นอกวลีที่แปลแล้ว)
    parts = re.split(r'(\u0000[^\u0001]*\u0001)', out)
    res = []
    for p in parts:
        if p.startswith('\u0000'):
            res.append(p[1:-1])
            continue
        q = p
        for en in sorted(WORDS, key=len, reverse=True):
            q = re.sub(r'(?<![a-z])' + re.escape(en) + r'(?![a-z])', WORDS[en], q)
        res.append(q)
    # รูปแบบทั่วไป: "b1s1" → B1S1, คำย่อกลับเป็นตัวใหญ่ (เฉพาะส่วนที่ไม่ได้มาจากวลีที่แปลแล้ว)
    def up(m):
        w = m.group(0)
        return w.upper() if w.upper() in KEEP else w
    fixed = []
    for i, seg in enumerate(res):
        if parts[i].startswith('\u0000'):
            fixed.append(seg)
            continue
        seg = re.sub(r'[a-z0-9][a-z0-9/+\-]*', up, seg)
        # ยังมีคำอังกฤษตัวเล็กเหลือ → แปลไม่ครบ
        if re.findall(r'[a-z]{2,}', seg):
            return None
        fixed.append(seg)
    th = ''.join(fixed)
    th = re.sub(r'\s+,', ',', th)
    th = re.sub(r',\s*', ' ', th)
    th = re.sub(r'\s+', ' ', th).strip()
    th = th.replace('( ', '(').replace(' )', ')')
    # "ค่าชดเชยหัวฉีด (feedback) สูบ 1" ฯลฯ คงไว้
    return th


if __name__ == '__main__':
    import sys
    ok = 0
    tot = 0
    for line in open(sys.argv[1]):
        n = line.rstrip('\n')
        if not n or n.startswith('PATHS') or n.startswith('UNITS'):
            continue
        tot += 1
        t = translate(n)
        if t:
            ok += 1
            print(f'{n}  =>  {t}')
    print(ok, '/', tot)
