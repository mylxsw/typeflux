import AppKit
import PDFKit
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
for name in ["plain", "rotated"] {
 let doc = PDFDocument(url: folder.appendingPathComponent(name + ".pdf"))!
 let p = doc.page(at: 1)!, ref = p.pageRef!
 print(name, "rotation",p.rotation,"media",p.bounds(for:.mediaBox),"crop",p.bounds(for:.cropBox), "refmedia",ref.getBoxRect(.mediaBox))
 let rect = CGRect(x:0,y:0,width:1040,height:780)
 print("transform",ref.getDrawingTransform(.mediaBox,rect:rect,rotate:0,preserveAspectRatio:true))
 let image = p.thumbnail(of: CGSize(width:1040,height:780),for:.mediaBox)
 let bmp = NSBitmapImageRep(cgImage:image.cgImage(forProposedRect:nil,context:nil,hints:nil)!)
 try bmp.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent(name+"-source.png"))
}
